OPTIONAL: use clawmon instead of mfilemon
=========================================

By default the installer uses "mfilemon" (Multi File Port Monitor) because it
ships prebuilt binaries. clawmon is a compatible fork but publishes no prebuilt
binaries, so it would otherwise require compiling from source.

If you want to use clawmon, place these three files in THIS folder and then run
install.bat again:

    clawmon.dll
    clawmonui.dll
    regmon.exe

The installer will detect them, copy the DLLs into System32, register the
monitor with `regmon.exe -r`, and create the port under
"clawmon printer port monitor" instead of "Multi File Port Monitor".

Everything else (registry port format, %t / %r / %f macros) is identical, so
upload.py and setup.ps1 work unchanged either way.

Get clawmon source: https://github.com/hessandrew/clawmon
