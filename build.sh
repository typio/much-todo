#!/bin/bash

# Exit on any error
set -e

TARGET_ENV="mac"

# Check script arguments for environment specification
if [ "$#" -eq 1 ]; then
  if [ "$1" == "mac" ] || [ "$1" == "linux" ]; then
    TARGET_ENV="$1"
  else
    echo "Invalid environment provided. Use 'mac' or 'linux'. Defaulting to 'mac'."
  fi
fi

echo "Building for $TARGET_ENV..."

# 1. Build the http-server
echo "Building http-server..."
cd http-server
if [ "$TARGET_ENV" == "mac" ]; then
    zig build
else
    zig build -Dtarget=x86_64-linux-gnu
fi
mkdir -p ../build/http-server
mv zig-out/bin/http-server ../build/http-server/
cd ..

# 2. Build the todo-app
# echo "Building todo-app..."
# cd todo-app
# make
# mkdir -p ../build/todo-app
# mv output-files ../build/todo-app/
# cd ..

# 3. Building frontend files
echo "Building frontend..."
mkdir -p build/frontend
cp -Rf frontend/* build/frontend/

echo "Build completed!"