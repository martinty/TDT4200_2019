#!/bin/bash -e

if [[ ! $OSTYPE =~ "linux" ]]; then
    echo "Only supported on Linux"
    exit 1
fi

N=${2:-1}
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd)"

function build_f {
    mkdir -p build
    mkdir -p program
    cd $SCRIPTPATH/build
    echo "------------- Running cmake -------------"
    cmake ..
}
function make_f {
    cd $SCRIPTPATH/build
    echo "------------- Running make --------------"
    make -j4
}
function run_f {
    cd $SCRIPTPATH/program
    echo "------------- Running program -----------"
    echo "Using $N processes"
    mpirun -np $N *.out
}
function clean_f {
    cd $SCRIPTPATH/build
    echo "------------- Running clean -------------"
    make clean
}
function remove_f {
    rm -f $SCRIPTPATH/program/*.out
    rm -f $SCRIPTPATH/program/after.bmp
    rm -rf $SCRIPTPATH/build
}

if [[ $1 == "build" ]]; then
    build_f
elif [[ $1 == "make" ]]; then
    make_f
elif [[ $1 == "run" ]]; then
    run_f
elif [[ $1 == "update" ]]; then
    make_f
    run_f
elif [[ $1 == "all" ]]; then
    build_f
    make_f
    run_f
elif [[ $1 == "clean" ]]; then
    clean_f
elif [[ $1 == "remove" ]]; then
    remove_f
else
    echo "Commands: "
    echo "      build"
    echo "      make"
    echo "      run <n>"
    echo "      update <n>"
    echo "      all <n>"
    echo "      clean"
    echo "      remove"
fi