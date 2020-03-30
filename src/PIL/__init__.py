"""Pillow (Fork of the Python Imaging Library)

Pillow is the friendly PIL fork by Alex Clark and Contributors.
    https://github.com/python-pillow/Pillow/

Pillow is forked from PIL 1.1.7.

PIL is the Python Imaging Library by Fredrik Lundh and Contributors.
Copyright (c) 1999 by Secret Labs AB.

Use PIL.__version__ for this Pillow version.

;-)
"""

import warnings

from . import _version

# VERSION was removed in Pillow 6.0.0.
__version__ = _version.__version__


class _Deprecated_Version(str):
    def _raise_warning(self):
        warnings.warn(
            "PILLOW_VERSION is deprecated and will be removed in a future release. "
            "Use __version__ instead.",
            DeprecationWarning,
            stacklevel=3,
        )

    def __getitem__(self, key):
        self._raise_warning()
        return super().__getitem__(key)

    def __eq__(self, other):
        self._raise_warning()
        return super().__eq__(other)


# PILLOW_VERSION is deprecated and will be removed in a future release.
# Use __version__ instead.
PILLOW_VERSION = _Deprecated_Version(__version__)

del _version


_plugins = [
    "BlpImagePlugin",
    "BmpImagePlugin",
    "BufrStubImagePlugin",
    "CurImagePlugin",
    "DcxImagePlugin",
    "DdsImagePlugin",
    "EpsImagePlugin",
    "FitsStubImagePlugin",
    "FliImagePlugin",
    "FpxImagePlugin",
    "FtexImagePlugin",
    "GbrImagePlugin",
    "GifImagePlugin",
    "GribStubImagePlugin",
    "Hdf5StubImagePlugin",
    "IcnsImagePlugin",
    "IcoImagePlugin",
    "ImImagePlugin",
    "ImtImagePlugin",
    "IptcImagePlugin",
    "JpegImagePlugin",
    "Jpeg2KImagePlugin",
    "McIdasImagePlugin",
    "MicImagePlugin",
    "MpegImagePlugin",
    "MpoImagePlugin",
    "MspImagePlugin",
    "PalmImagePlugin",
    "PcdImagePlugin",
    "PcxImagePlugin",
    "PdfImagePlugin",
    "PixarImagePlugin",
    "PngImagePlugin",
    "PpmImagePlugin",
    "PsdImagePlugin",
    "SgiImagePlugin",
    "SpiderImagePlugin",
    "SunImagePlugin",
    "TgaImagePlugin",
    "TiffImagePlugin",
    "WebPImagePlugin",
    "WmfImagePlugin",
    "XbmImagePlugin",
    "XpmImagePlugin",
    "XVThumbImagePlugin",
]


class UnidentifiedImageError(IOError):
    pass
