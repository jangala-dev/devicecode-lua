#!/bin/sh

cd /tmp
git clone https://github.com/jangala-dev/lua-fibers
cd lua-fibers
git checkout v0.4
sudo cp -r src/* /workspaces/lua-bus/src/
cd ..
rm -rf lua-fibers

cd /tmp
git clone https://github.com/jangala-dev/lua-trie
cd lua-trie
git checkout v0.2
sudo mv src/trie.lua /workspaces/lua-bus/src/
cd ..
rm -rf lua-trie

exit 0
