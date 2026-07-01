#!/bin/bash
# Build the PathTo A* determinism validator. -ffp-contract=off keeps float ops
# bit-reproducible (no FMA fusion). 64-bit by default; also try 32-bit (matches the
# 32-bit worker DLL / game) if a multilib g++ is available.
set -e
cd "$(dirname "$0")"
g++ -O2 -ffp-contract=off -o validate validate.cpp
echo "built: validate (64-bit)"
if echo 'int main(){return 0;}' | g++ -m32 -x c++ - -o /tmp/_m32test 2>/dev/null; then
    g++ -m32 -O2 -ffp-contract=off -o validate32 validate.cpp
    echo "built: validate32 (32-bit)"
    rm -f /tmp/_m32test
else
    echo "(skip 32-bit: no multilib g++; install g++-multilib to build validate32)"
fi
