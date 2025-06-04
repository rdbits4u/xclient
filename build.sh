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
    cd ../xclient
    rm -f -r .zig-cache/ zig-out/
    exit 0
fi

if [ "$1" = "debug" ]
then
    cd ../rdpc
    zig build --summary all
    if test $? -eq 0
    then
        cd ../svc
        zig build --summary all
        if test $? -eq 0
        then
            cd ../cliprdr
            zig build --summary all
            if test $? -eq 0
            then
                cd ../xclient
                zig build --summary all
            fi
        fi
    fi
else
    cd ../rdpc
    zig build -Dtarget=x86_64-native -Doptimize=ReleaseFast -Dstrip=true --summary all
    if test $? -eq 0
    then
        cd ../svc
        zig build -Dtarget=x86_64-native -Doptimize=ReleaseFast -Dstrip=true --summary all
        if test $? -eq 0
        then
            cd ../cliprdr
            zig build -Dtarget=x86_64-native -Doptimize=ReleaseFast -Dstrip=true --summary all
            if test $? -eq 0
            then
                cd ../xclient
                zig build -Dtarget=x86_64-native -Doptimize=ReleaseFast -Dstrip=true --summary all
            fi
        fi
    fi
fi
