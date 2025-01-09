#!/bin/sh

make env
make lint

ret=$?
if [ $ret -ne 0 ]; then
	exit $ret
fi

make test
ret=$?
if [ $ret -ne 0 ]; then
	exit $ret
fi

exit 0
