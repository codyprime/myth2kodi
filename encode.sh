#!/bin/bash
# Simple helper script for myth2kodi.pl

encoder="$8"

scale=
if [ "$7" != "-1" ]
then
    if [ "$encoder" == "ffmpeg" ]
    then
        scale="scale=$7:-1,"
    else
        scale="-X $7"
    fi
fi

deint_opts=
if [ "$3" == "interlaced" ]
then
    if [ "$encoder" == "ffmpeg" ]
    then
        deint_opts="-vf ${scale}yadif=3:-1:0"
    else
        deint_opts="--deinterlace=bob"
    fi
fi

x264_preset=
if [ "$4" != "" ]
then
    if [ "$encoder" == "ffmpeg" ]
    then
        x264_preset="$4"
    else
        x264_preset="--x264-preset $4"
    fi
fi

err_log="/dev/null"
if [ "$5" != "" ]
then
    err_log=$5
fi

dry_run=
if [ "$6" != "-1" ]
then
    dry_run=$6
fi

if [ "$encoder" == "ffmpeg" ]
then
    cmd="ffmpeg -i \"$1\" \
        ${deint_opts} -c:v libx264  -preset ${x264_preset} -c:a:0 copy -crf 19.7 \
        -tune film \
        -movflags faststart \
        -loglevel panic -stats"

    full_cmd="${cmd} \"$2\""

#    -x264opts merange=24:trellis=2:keyint=600:min-keyint=60:rc-lookahead=60:vbv-maxrate=62500:vbv-bufsize=78125:nal-hrd=none \
#    -me_range 16 -trellis 2 -g 600 -keyint_min 60 -maxrate 62500 -tune film -loglevel panic -stats"
#cmd="ffmpeg -i \"$1\" \
#    ${deint_opts} -c:v libx264  -preset ${x264_preset} -c:a:0 copy -crf 20 -loglevel panic -stats"
else
    cmd="HandBrakeCLI -Z \"High Profile\" -a 1 -E copy -O ${deint_opts} ${x264_preset} ${scale}"
    full_cmd="${cmd} -i \"$1\" -o \"$2\"  2>\"${err_log}\""
fi
echo ${cmd} "[...]" | fmt -t


if [ "$dry_run" != "dry-run" ]
then
    eval ${full_cmd}
fi

