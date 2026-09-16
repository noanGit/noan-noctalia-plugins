// scopebar.go is the native audio side of the Noctalia scopebar widget.
//
// It intentionally has a very small protocol: it reads mono f32le samples
// from stdin and atomically replaces --output with
//
//	<detected-pitch-hz>;<sample>,<sample>,...
//
// The Luau widget polls that file.  Keeping audio capture and DSP here means
// that the VM only has to parse a short line and turn it into braille.
package main

import (
	"bufio"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const bufferSize = 32768

func clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// Biquad is a transposed-free, direct-form II biquad.  The state is kept
// between calls for the display path, just as it is in the original C++
// implementation.
type Biquad struct {
	b0, b1, b2, a1, a2 float64
	x1, x2, y1, y2     float64
}

func (b *Biquad) reset() { b.x1, b.x2, b.y1, b.y2 = 0, 0, 0, 0 }

func (b *Biquad) process(x float64) float64 {
	y := b.b0*x + b.b1*b.x1 + b.b2*b.x2 - b.a1*b.y1 - b.a2*b.y2
	b.x2, b.x1 = b.x1, x
	b.y2, b.y1 = b.y1, y
	return y
}

func (b *Biquad) lowpass(fc, fs, q float64) {
	fc = clamp(fc, 1, fs*0.48)
	w := 2 * math.Pi * fc / fs
	alpha := math.Sin(w) / (2 * q)
	c := math.Cos(w)
	a0 := 1 + alpha
	b.b0 = ((1 - c) / 2) / a0
	b.b1 = (1 - c) / a0
	b.b2 = b.b0
	b.a1 = -2 * c / a0
	b.a2 = (1 - alpha) / a0
}

func (b *Biquad) highShelf(fc, fs, db, slope float64) {
	fc = clamp(fc, 1, fs*0.48)
	w := 2 * math.Pi * fc / fs
	c, s := math.Cos(w), math.Sin(w)
	A := math.Pow(10, db/40)
	alpha := s / 2 * math.Sqrt((A+1/A)*(1/slope-1)+2)
	beta := 2 * math.Sqrt(A) * alpha
	a0 := (A + 1) - (A-1)*c + beta
	b.b0 = (A * ((A + 1) + (A-1)*c + beta)) / a0
	b.b1 = (-2 * A * ((A - 1) + (A+1)*c)) / a0
	b.b2 = (A * ((A + 1) + (A-1)*c - beta)) / a0
	b.a1 = (2 * ((A - 1) - (A+1)*c)) / a0
	b.a2 = ((A + 1) - (A-1)*c - beta) / a0
}

func (b *Biquad) bandpass(center, fs, q float64) {
	center = clamp(center, 2, fs*0.45)
	w := 2 * math.Pi * center / fs
	alpha := math.Sin(w) / (2 * q)
	a0 := 1 + alpha
	b.b0 = alpha / a0
	b.b1 = 0
	b.b2 = -alpha / a0
	b.a1 = -2 * math.Cos(w) / a0
	b.a2 = (1 - alpha) / a0
}

// FIR is a windowed-sinc linear-phase bandpass.  The C++ example uses a
// linear-phase FIR for its trigger.  A bounded 2049-tap filter is used here:
// it keeps the helper realtime even for very low notes while retaining the
// important property (one stable rising crossing per period).
type FIR struct {
	coeff []float64
	hist  []float64
	pos   int
	delay int
}

func sinc(x float64) float64 {
	if math.Abs(x) < 1e-12 {
		return 1
	}
	return math.Sin(math.Pi*x) / (math.Pi * x)
}

// besselI0 is the standard short polynomial/asymptotic approximation used
// for the Kaiser window.  Keeping it here avoids a third-party DSP library.
func besselI0(x float64) float64 {
	ax := math.Abs(x)
	if ax < 3.75 {
		y := x / 3.75
		y *= y
		return 1 + y*(3.5156229+y*(3.0899424+y*(1.2067492+y*(0.2659732+y*(0.0360768+y*0.0045813)))))
	}
	y := 3.75 / ax
	return math.Exp(ax) / math.Sqrt(2*math.Pi*ax) * (0.39894228 + y*(0.01328592+y*(0.00225319+y*(-0.00157565+y*(0.00916281+y*(-0.02057706+y*(0.02635537+y*(-0.01647633+y*0.00392377))))))))
}

func (f *FIR) designBandpass(center, bandwidth, fs float64) {
	bandwidth = clamp(bandwidth, 4, fs*0.2)
	center = clamp(center, bandwidth*0.6, fs*0.44)
	// More taps for narrower bands, but cap the work done per input sample.
	taps := int(2*math.Round(fs/math.Max(bandwidth, 1))) + 1
	if taps < 257 {
		taps = 257
	}
	if taps > 513 {
		// The original uses a native FIR implementation.  A Go helper must
		// leave enough CPU for PipeWire and Noctalia; 513 taps still gives a
		// narrow, linear-phase trigger and is bounded at realtime rates.
		taps = 513
	}
	if taps%2 == 0 {
		taps++
	}
	f.coeff = make([]float64, taps)
	f.hist = make([]float64, taps)
	f.pos = 0
	f.delay = taps / 2
	lo := clamp(center-bandwidth/2, 1, fs*0.49)
	hi := clamp(center+bandwidth/2, lo+1, fs*0.49)
	beta := 0.1102 * (60 - 8.7) // approximately 60 dB Kaiser window
	for n := 0; n < taps; n++ {
		x := float64(n - taps/2)
		ideal := 2*hi/fs*sinc(2*hi*x/fs) - 2*lo/fs*sinc(2*lo*x/fs)
		r := 2*float64(n)/float64(taps-1) - 1
		window := besselI0(beta*math.Sqrt(math.Max(0, 1-r*r))) / besselI0(beta)
		f.coeff[n] = ideal * window
	}
	// Give a sine at the centre approximately unity gain.
	gain := 0.0
	for n, c := range f.coeff {
		gain += c * math.Cos(2*math.Pi*center*float64(n-taps/2)/fs)
	}
	if math.Abs(gain) > 1e-9 {
		for i := range f.coeff {
			f.coeff[i] /= gain
		}
	}
}

func (f *FIR) process(x float64) float64 {
	if len(f.coeff) == 0 {
		return x
	}
	f.hist[f.pos] = x
	y := 0.0
	j := f.pos
	for _, c := range f.coeff {
		y += c * f.hist[j]
		j--
		if j < 0 {
			j = len(f.hist) - 1
		}
	}
	f.pos++
	if f.pos == len(f.hist) {
		f.pos = 0
	}
	return y
}

func (f *FIR) reset() {
	for i := range f.hist {
		f.hist[i] = 0
	}
	f.pos = 0
}

// Oscilloscope is the Go counterpart of example/oscilloscope.cpp.  All
// indexes are circular-buffer indexes; the fractional trigger is retained
// until getSamplesInterpolated so a moving trigger does not visibly jitter.
type Oscilloscope struct {
	sampleRate   float64
	pitchLock    bool
	display      int
	writePos     int
	raw          []float64
	filtered     []float64
	displayBuf   []float64
	visual       []float64
	bandpass     FIR
	lastFilterHz float64
	pitchShelf   Biquad
	displayShelf Biquad
	low1, low2   Biquad
	pitchLow1    Biquad
	pitchLow2    Biquad
	smoothedHz   float64
	latestHz     float64
	pitchFrames  int
	analysisTick int
}

func NewOscilloscope(rate float64, display int, lock bool) *Oscilloscope {
	o := &Oscilloscope{
		sampleRate: rate, display: display, pitchLock: lock,
		raw: make([]float64, bufferSize), filtered: make([]float64, bufferSize),
		displayBuf: make([]float64, bufferSize), visual: make([]float64, bufferSize),
		lastFilterHz: 200,
	}
	o.configureFilters()
	return o
}

func (o *Oscilloscope) configureFilters() {
	o.bandpass.designBandpass(o.lastFilterHz, o.lastFilterHz*0.1, o.sampleRate)
	o.pitchShelf.highShelf(400, o.sampleRate, -3, 0.71)
	o.displayShelf.highShelf(400, o.sampleRate, -3, 0.71)
	o.low1.lowpass(18000, o.sampleRate, 0.707)
	o.low2.lowpass(18000, o.sampleRate, 0.707)
	o.pitchLow1.lowpass(18000, o.sampleRate, 0.707)
	o.pitchLow2.lowpass(18000, o.sampleRate, 0.707)
}

func (o *Oscilloscope) push(x float64) {
	x = clamp(x, -1, 1)
	o.raw[o.writePos] = x
	o.filtered[o.writePos] = o.bandpass.process(x)
	d := o.low1.process(x)
	d = o.low2.process(d)
	o.displayBuf[o.writePos] = d
	o.visual[o.writePos] = o.displayShelf.process(d)
	o.writePos++
	if o.writePos == bufferSize {
		o.writePos = 0
	}
}

func (o *Oscilloscope) recent(dst []float64) {
	start := o.writePos - len(dst)
	for i := range dst {
		idx := (start + i) % bufferSize
		if idx < 0 {
			idx += bufferSize
		}
		dst[i] = o.displayBuf[idx]
	}
}

// fftPitch is a small radix-2 FFT pitch estimator.  It is the Go equivalent
// of the detectPitchFFT call used by the example and deliberately searches
// only the musical range used by the widget.
func fftPitch(samples []float64, fs float64) float64 {
	n := 1
	for n < len(samples) {
		n <<= 1
	}
	if n > 4096 {
		n = 4096
	}
	x := make([]complex128, n)
	mean := 0.0
	for _, v := range samples {
		mean += v
	}
	mean /= math.Max(1, float64(len(samples)))
	for i := 0; i < len(samples) && i < n; i++ {
		w := 0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(len(samples)-1))
		x[i] = complex((samples[i]-mean)*w, 0)
	}
	for i, j := 1, 0; i < n; i++ {
		bit := n >> 1
		for ; j&bit != 0; bit >>= 1 {
			j ^= bit
		}
		j ^= bit
		if i < j {
			x[i], x[j] = x[j], x[i]
		}
	}
	for length := 2; length <= n; length <<= 1 {
		angle := -2 * math.Pi / float64(length)
		wlen := complex(math.Cos(angle), math.Sin(angle))
		for i := 0; i < n; i += length {
			w := complex(1, 0)
			for j := 0; j < length/2; j++ {
				u, v := x[i+j], x[i+j+length/2]*w
				x[i+j], x[i+j+length/2] = u+v, u-v
				w *= wlen
			}
		}
	}
	minBin := int(40 * float64(n) / fs)
	maxBin := int(1000 * float64(n) / fs)
	if minBin < 1 {
		minBin = 1
	}
	if maxBin >= n/2 {
		maxBin = n/2 - 1
	}
	best, bestMag := 0, 0.0
	for k := minBin; k <= maxBin; k++ {
		mag := real(x[k])*real(x[k]) + imag(x[k])*imag(x[k])
		// Mild harmonic summing makes the fundamental win over a loud second
		// harmonic without requiring a heavyweight pitch tracker.
		for h, weight := 2, 0.45; h <= 4; h, weight = h+1, weight*0.55 {
			bin := k * h
			if bin < n/2 {
				mag += weight * (real(x[bin])*real(x[bin]) + imag(x[bin])*imag(x[bin]))
			}
		}
		if mag > bestMag {
			best, bestMag = k, mag
		}
	}
	if best == 0 || bestMag < 1e-8 {
		return 0
	}
	return float64(best) * fs / float64(n)
}

func (o *Oscilloscope) analysePitch() {
	// The C++ reference resets the analysis chain for every snapshot.  The
	// same is important here because `recent` is a circular-buffer snapshot,
	// not a continuous stream into these three analysis filters.
	o.pitchShelf.reset()
	o.pitchLow1.reset()
	o.pitchLow2.reset()
	recent := make([]float64, 2048)
	o.recent(recent)
	for i := range recent {
		recent[i] = o.pitchShelf.process(recent[i])
		recent[i] = o.pitchLow1.process(recent[i])
		recent[i] = o.pitchLow2.process(recent[i])
	}
	p := fftPitch(recent, o.sampleRate)
	if p <= 0 {
		return
	}
	o.latestHz = p
	o.pitchFrames++
	if o.smoothedHz == 0 {
		o.smoothedHz = p
	} else {
		old := 0.95
		if o.pitchFrames < 20 {
			old = 0.5
		}
		o.smoothedHz = o.smoothedHz*old + p*(1-old)
	}
	if o.lastFilterHz <= 0 || math.Abs(o.smoothedHz-o.lastFilterHz)/o.lastFilterHz > 0.1 {
		o.lastFilterHz = o.smoothedHz
		o.bandpass.designBandpass(o.lastFilterHz, o.lastFilterHz*0.1, o.sampleRate)
	}
}

func (o *Oscilloscope) findTrigger(target, span int) float64 {
	if o.smoothedHz <= 0 {
		return float64(target)
	}
	period := o.sampleRate / o.smoothedHz
	if period < 2 {
		period = 2
	}
	for i := 0; i < span && i < bufferSize; i++ {
		pos := target - i
		for pos < 0 {
			pos += bufferSize
		}
		pos %= bufferSize
		prev := pos - 1
		if prev < 0 {
			prev += bufferSize
		}
		a, b := o.filtered[prev], o.filtered[pos]
		if a < 0 && b >= 0 {
			look := int(period / 4)
			if look < 4 {
				look = 4
			}
			if look > 256 {
				look = 256
			}
			peak := 0.0
			for j := 0; j < look; j++ {
				v := math.Abs(o.filtered[(pos+j)%bufferSize])
				if v > peak {
					peak = v
				}
			}
			if peak > 0.01 && b != a {
				return float64(prev) - a/(b-a)
			}
		}
	}
	return -1
}

func (o *Oscilloscope) sampleAt(pos float64) float64 {
	for pos < 0 {
		pos += bufferSize
	}
	for pos >= bufferSize {
		pos -= bufferSize
	}
	i := int(pos)
	f := pos - float64(i)
	i0 := (i - 1 + bufferSize) % bufferSize
	i1 := i
	i2 := (i + 1) % bufferSize
	i3 := (i + 2) % bufferSize
	y0, y1, y2, y3 := o.visual[i0], o.visual[i1], o.visual[i2], o.visual[i3]
	return 0.5 * (2*y1 + (-y0+y2)*f + (2*y0-5*y1+4*y2-y3)*f*f + (-y0+3*y1-3*y2+y3)*f*f*f)
}

func (o *Oscilloscope) frame(points int) ([]float64, float64) {
	if points < 2 {
		points = 2
	}
	start := o.writePos - o.display
	if o.pitchLock && o.smoothedHz > 0 {
		period := o.sampleRate / o.smoothedHz
		target := start - o.bandpass.delay
		cross := o.findTrigger(target, int(period*4))
		if cross >= 0 {
			start = int(math.Round(cross)) - o.bandpass.delay
		}
	}
	out := make([]float64, points)
	span := float64(o.display)
	for i := range out {
		p := float64(start) + span*float64(i)/float64(points-1)
		out[i] = o.sampleAt(p)
	}
	return out, o.smoothedHz
}

func writeFrame(path string, values []float64, pitch float64) error {
	var b strings.Builder
	b.Grow(16 + len(values)*8)
	b.WriteString(strconv.FormatFloat(pitch, 'f', 2, 64))
	b.WriteByte(';')
	for i, v := range values {
		if i != 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatFloat(clamp(v, -1, 1), 'f', 4, 64))
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func main() {
	output := flag.String("output", "/tmp/noctalia-scopebar-go.csv", "atomic frame output")
	rate := flag.Float64("rate", 48000, "input sample rate")
	keep := flag.Int("keep", 16, "keep every Nth input sample")
	points := flag.Int("points", 96, "samples in one output frame")
	display := flag.Int("display", 2048, "samples in the display window")
	lock := flag.Bool("pitch-lock", true, "lock the display to the detected pitch")
	flag.Parse()
	if *keep < 1 {
		*keep = 1
	}
	if *points < 2 {
		*points = 2
	}
	if *display < 64 || *display >= bufferSize {
		*display = 2048
	}
	outDir := filepath.Dir(*output)
	if outDir != "." {
		if err := os.MkdirAll(outDir, 0755); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	// DSP stays at the input rate, matching the C++ reference.  `keep` only
	// throttles how often a frame is exported; decimating before the filters
	// would alias high-frequency audio into the trigger signal.
	o := NewOscilloscope(*rate, *display, *lock)
	input := bufio.NewReaderSize(os.Stdin, 64*1024)
	var frameTick, inputCount uint64
	var bytes [4]byte
	for {
		if _, err := io.ReadFull(input, bytes[:]); err != nil {
			break
		}
		x := float64(math.Float32frombits(binary.LittleEndian.Uint32(bytes[:])))
		o.push(x)
		if inputCount%uint64(*keep) == 0 {
			frameTick++
			// At 48 kHz / 16 this is about 3000 frame opportunities per
			// second; export every 48 of them (~62 Hz).  The widget itself is
			// refreshed at 60 Hz and simply sees the latest frame.
			if frameTick%48 == 0 {
				o.analysisTick++
				if o.analysisTick%2 == 0 {
					o.analysePitch()
				}
				values, pitch := o.frame(*points)
				_ = writeFrame(*output, values, pitch)
			}
		}
		inputCount++
	}
}
