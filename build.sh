#!/bin/sh

if test -d "../rdpc"
then
    echo "Directory ../rdpc exists"
else
    echo "Directory ../rdpc does not exits"
    exit 1
fi
if [ "$1" = "clean" ]
then
    cd ../rdpc
    rm -f -r .zig-cache/ zig-out/
    cd ../svc
    rm -f -r .zig-cache/ zig-out/
    cd ../cliprdr
    rm -f -r .zig-cache/ zig-out/
    cd ../rdpsnd
    rm -f -r .zig-cache/ zig-out/
    cd ../xclient
    rm -f -r .zig-cache/ zig-out/
    exit 0
fi

if [ "$1" = "debug" ]
then
    cd ../rdpc
    zig build --summary all
    if test $? -ne 0
    then
        exit 1
    fi
    cd ../svc
    zig build --summary all
    if test $? -ne 0
    then
        exit 1
    fi
    cd ../cliprdr
    zig build --summary all
    if test $? -ne 0
    then
        exit 1
    fi
    cd ../rdpsnd
    zig build --summary all
    if test $? -ne 0
    then
        exit 1
    fi
    cd ../xclient
    zig build --summary all
    if test $? -ne 0
    then
        exit 1
    fi
    exit 0
fi

cd ../rdpc
zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
if test $? -ne 0
then
    exit 1
fi
cd ../svc
zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
if test $? -ne 0
then
    exit 1
fi
cd ../cliprdr
zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
if test $? -ne 0
then
    exit 1
fi
cd ../rdpsnd
zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
if test $? -ne 0
then
    exit 1
fi
cd ../xclient
zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
