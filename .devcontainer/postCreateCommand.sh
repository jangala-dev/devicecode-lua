#!/bin/sh

sudo apt update -y

sudo apt install -y apt-utils unzip curl wget git build-essential libreadline-dev dialog libssl-dev m4

# install core lua packages

sudo apt install -y lua5.1 liblua5.1-dev luajit luarocks lua-dkjson

# install luarocks packages

sudo luarocks install bit32
sudo luarocks install cqueues
sudo luarocks install http
sudo luarocks install luaposix

# install cffi-lua

sudo apt install -y meson pkg-config cmake libffi-dev

cd /tmp
sudo rm -rf cffi-lua
git clone https://github.com/q66/cffi-lua
mkdir cffi-lua/build
cd cffi-lua/build
sudo meson .. -Dlua_version=5.1 --buildtype=release
sudo ninja all
sudo ninja test
sudo cp cffi.so /usr/local/lib/lua/5.1/cffi.so

exit 0
