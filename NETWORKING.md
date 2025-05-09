# Networking
This document describes networking with device code


```
      System     Modem       WiFi
    ____|__________|__________|_____
   |                                |
   |              BUS               |
   |________________________________|
    ______________ | ________________
   |                                |
   |              HUB               |= WS Transport
   |________________________________|
        |       |      ...      |
        o       o      ...      o
      conn_1  conn_2         conn_N


```

BUS - The internal bus on a device.

HUB - A manager of connections between buses on different devices.

System, Modem, WiFi - Internal microservices generating telemetry and accepting commands through messages.

Conn - A connection to a transport protocol that can send or receive messages.  Transport protocols are WebSocket, HTTP, UART, FileDescriptor


## Overview

Inter-device communication is made by connecting buses.
Each device runs a hub, which shepherds messages between their bus and a remote endpoint using connections.
There are a few different types of connections which use different transport protocols.  

### HTTPConnection

Forwards messages from a bus to a remote HTTP endpoint.  This is currently tailored to sending messages to Mainflux by wrapping the topic up in the URL and adding the appropriate headers.  This could be configured from config to make the connection generic.  
HTTPConnection is send-only.

### WSConnection

Forms a full connection to a bus, both sending and receiving messages.  The WSConnection wraps a websocket.
The websocket must be upgraded from an HTTP endpoint, which is set up as standard on the hub object, using a WSTransport object.
When a remote connection contacts the http endpoint, a websocket is created and wrapped in a WSConnection which is added to the hub.

### FDConnection

An FDConnection wraps a File Descriptor.  This is useful for communicating with a connected device who's messages appear in a linux file descriptor (USB, Serial Port, UART etc.).  Messages are sent and read by opening, then reading or appending to the file descriptor.  

## Message Structure

  {"type":"publish|subscribe", "topic":"#|+|aaa.bbb...", "payload":[{"n":"metric_name","v":0}]}

type: publish or subscribe.
topic: '.' separated topic chain, with wildcards.  
payload: Array of Senml messages.

Each message is sent surrounded by a message start byte (2) and a message end byte (3).  This ensures that incomplete messages are not used and allows processing of a stream of bytes, sent individually or made available in chunks.  As soon as a message end byte is received, the message is processed.

## Message Filtering

By default, each connection sends/receives all messages on the bus to/from the transport protocol it uses.
It does this by subscribing to the bus with the topic '#', which is a wildcard which matches all topics.

TODO:
Topics can be filtered for individual connections by using a topic field in config
Each message on a bus should be sent with a bus_connection_id so that no messaage is re-published by the sender who subscribes to '#'

## Real World Example

Inside a Bigbox we connect a Pi Pico to a Pi CM5 to Jangala cloud platform.

```
   ------------               -------------                -------------   
  |            | UART     FD |             | HTTP    HTTP |             |
  |    PICO    |-o ------- o-|     CM5     |-o ------- o- |    CLOUD    |
  |            |             |             |              |             |
   ------------               -------------                -------------

```

The Pico sends/reads messages to/from a UART pins using a UARTConnection

Pico is connected to the CM5 over UART

The CM5 sends/reads messages to/from a FileDescriptor at /dev/tty.xxx which corresponds to the UART connection

config.json:
```
{
  "type": "fd",
  "path_read": "/dev/tty.xxx",
  "path_send": "/dev/tty.xxx"
}
```

CM5 is connected to the cloud over HTTP

The CM5 sends messages to an HTTP endpoint hosted in the cloud

config.json:
```
{
  "type": "http",
  "url": "http://cloud.dev.janga.la/http/channels/{channel}/messages",
  "mainflux_id":"{ID}",
  "mainflux_key":"{KEY}",
  "mainflux_datachannel":"{DATACHANNEL_ID}"
}
```

## Development Environment

There is a dev container provided for development in an Ubuntu container which has the same libraries that are loaded onto a real device.

Docker on MacOS Arm architecture has a problem forwarding ports into containers, so it is difficult to connect the devcontainer to a real external device connected to the development machine.
There are two methods provided for development:

### 1. Fake device
devices/dev-device.lua creates a 'testdevice', implemented in testdevice.lua.
This is a rudimentary testing device which published a standard message at a constant interval into a known file.
That file can be used as the file descriptor in FDConnection by matching the file paths in config.json:

```
"hub": {
    "connections": [
        {
            "type": "fd",
            "path_read": "/tmp/dc_bus_read",
            "path_send": "/tmp/dc_bus_send"
        }
    ]
},
"testdevice": {
    "fd_path": "/tmp/dc_bus_read",
    "interval": 10
}
```

### 2. Websockets
A second virtual device running in a devcontainer can be connected to this one using a websocket connection as long as they are added to the same network.

The Pico version of devicecode has a websocket client adapter which connects its bus to a remote websocket server.

The Websocket url and port in the Pico version should match the url and port set up in config.json here:
```
"hub": {
  "ws_host": "172.19.0.2",
  "ws_port": "9003",
  ...
```
