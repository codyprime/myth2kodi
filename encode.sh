#!/bin/bash
# Simple helper script for myth2kodi.pl

deint_opts=
if [ "$3" == "interlaced" ]
then
    deint_opts="--deinterlace=bob -r 59.94"
fi

x264_preset=
if [ "$4" != "" ]
then
    x264_preset="--x264-preset $4"
fi

err_log="/dev/null"
if [ "$5" != "" ]
then
    err_log=$5
fi

dry_run=
if [ "$6" != "" ]
then
    dry_run=$6
fi

cmd="HandBrakeCLI -Z \"High Profile\" -a 1 -E copy -O ${deint_opts} --cfr ${x264_preset}"
full_cmd="${cmd} -i \"$1\" -o \"$2\"  2>\"${err_log}\""
echo ${cmd} "[...]"


if [ "$dry_run" != "dry-run" ]
then
    eval ${full_cmd}
fi

