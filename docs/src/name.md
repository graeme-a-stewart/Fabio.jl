# Fabio and slix names

## History

- silx stands for ScIentific Library for eXperimentalists. Developed primarily
by the European Synchrotron Radiation Facility (ESRF), it provides a unified
set of Python modules and widgets to support data assessment, reduction, and
analysis across various beamlines.

- fabio stands for Fable Input/Output, which may come itself from "Fully
Automated BeamLine Experiments" or "A Framework for Automating Beamline
Experiments"

> *fabio* It was originally written as the dedicated image I/O handling module for the Fable project (Fast Analysis of Bulk Layers of Elastics)—an open-source software suite designed to analyze 2D X-ray detector data at light sources. **This is a hallucination from Google Gemini**

## Our package

This package started as a port of fabio, but has since extended to features found in the more modern silx.io package.

Therefore `Fabio.jl` doesn't actually seem to be appropriate any more (especially give it's weird origin).

### Proposal

This is a package for X-ray data IO, so `Xrio.jl` could be a good option.
