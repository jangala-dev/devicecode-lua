#!/bin/sh

sudo apt update -y

sudo apt install -y apt-utils unzip curl wget git build-essential libreadline-dev dialog libssl-dev m4

# install core lua packages

sudo apt install -y lua5.1 liblua5.1-dev luajit luarocks lua-dkjson

sudo apt-get update
sudo apt-get install libmosquitto-dev

# install luarocks packages

sudo luarocks install bit32
sudo luarocks install cqueues
sudo luarocks install http
sudo luarocks install luaposix
sudo luarocks install lua-mosquitto

cd /tmp
sudo git clone https://github.com/facebook/luaffifb
cd luaffifb
sudo luarocks make

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

# install go
cd /tmp

arch=$(uname -m)

if [ "$arch" = "aarch64" ]
then
   wget https://go.dev/dl/go1.21.0.linux-arm64.tar.gz
else
   wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
fi
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.21.0.linux*.tar.gz
echo "export PATH=$PATH:/usr/local/go/bin" >> $HOME/.profile
echo "export PATH=$PATH:/usr/local/go/bin" >> $HOME/.bashrc

exit 0