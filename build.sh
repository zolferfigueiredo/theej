#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -o .build/DeJota Sources/deej-mac/main.swift
echo "Built: .build/DeJota"
