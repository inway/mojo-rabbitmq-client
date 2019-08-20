[![Build Status](https://travis-ci.org/inway/mojo-rabbitmq-client.svg?branch=master)](https://travis-ci.org/inway/mojo-rabbitmq-client) [![MetaCPAN Release](https://badge.fury.io/pl/Mojo-RabbitMQ-Client.svg)](https://metacpan.org/release/Mojo-RabbitMQ-Client)
# NAME

Mojo::RabbitMQ::Client - Mojo::IOLoop based RabbitMQ client

# SYNOPSIS

```perl
use Mojo::RabbitMQ::Client;

# Supply URL according to (https://www.rabbitmq.com/uri-spec.html)
my $client = Mojo::RabbitMQ::Client->new(
  url => 'amqp://guest:guest@127.0.0.1:5672/');

# Catch all client related errors
$client->catch(sub { warn "Some error caught in client"; });

# When connection is in Open state, open new channel
$client->on(
  open => sub {
    my ($client) = @_;

    # Create a new channel with auto-assigned id
    my $channel = Mojo::RabbitMQ::Client::Channel->new();

    $channel->catch(sub { warn "Error on channel received"; });

    $channel->on(
      open => sub {
        my ($channel) = @_;
        $channel->qos(prefetch_count => 1)->deliver;

        # Publish some example message to test_queue
        my $publish = $channel->publish(
          exchange    => 'test',
          routing_key => 'test_queue',
          body        => 'Test message',
          mandatory   => 0,
          immediate   => 0,
          header      => {}
        );
        # Deliver this message to server
        $publish->deliver;

        # Start consuming messages from test_queue
        my $consumer = $channel->consume(queue => 'test_queue');
        $consumer->on(message => sub { say "Got a message" });
        $consumer->deliver;
      }
    );
    $channel->on(close => sub { $log->error('Channel closed') });

    $client->open_channel($channel);
  }
);

# Start connection
$client->connect();

# Start Mojo::IOLoop if not running already
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
```

## CONSUMER

```perl
use Mojo::RabbitMQ::Client;
my $consumer = Mojo::RabbitMQ::Client->consumer(
  url      => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo',
  defaults => {
    qos      => {prefetch_count => 1},
    queue    => {durable        => 1},
    consumer => {no_ack         => 0},
  }
);

$consumer->catch(sub { die "Some error caught in Consumer" } );
$consumer->on('success' => sub { say "Consumer ready" });
$consumer->on(
  'message' => sub {
    my ($consumer, $message) = @_;

    $consumer->channel->ack($message)->deliver;
  }
);
$consumer->start();

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
```

## PUBLISHER

```perl
use Mojo::RabbitMQ::Client;
my $publisher = Mojo::RabbitMQ::Client->publisher(
  url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&routing_key=mojo'
);

$publisher->publish('plain text');

$publisher->publish(
  {encode => { to => 'json'}},
  routing_key => 'mojo_mq'
)->then(sub {
  say "Message published";
})->catch(sub {
  die "Publishing failed"
})->wait;
```

# DESCRIPTION

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) is a rewrite of [AnyEvent::RabbitMQ](https://metacpan.org/pod/AnyEvent::RabbitMQ) to work on top of [Mojo::IOLoop](https://metacpan.org/pod/Mojo::IOLoop).

# EVENTS

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) inherits all events from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter) and can emit the
following new ones.

## connect

```perl
$client->on(connect => sub {
  my ($client, $stream) = @_;
  ...
});
```

Emitted when TCP/IP connection with RabbitMQ server is established.

## open

```perl
$client->on(open => sub {
  my ($client) = @_;
  ...
});
```

Emitted AMQP protocol Connection.Open-Ok method is received.

## close

```perl
$client->on(close => sub {
  my ($client) = @_;
  ...
});
```

Emitted on reception of Connection.Close-Ok method.

## disconnect

```perl
$client->on(close => sub {
  my ($client) = @_;
  ...
});
```

Emitted when TCP/IP connection gets disconnected.

# ATTRIBUTES

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) has following attributes.

## tls

```perl
my $tls = $client->tls;
$client = $client->tls(1)
```

Force secure connection. Default is disabled (`0`).

## user

```perl
my $user = $client->user;
$client  = $client->user('guest')
```

Sets username for authorization, by default it's not defined.

## pass

```perl
my $pass = $client->pass;
$client  = $client->pass('secret')
```

Sets user password for authorization, by default it's not defined.

## host

```perl
my $host = $client->host;
$client  = $client->host('localhost')
```

Hostname or IP address of RabbitMQ server. Defaults to `localhost`.

## port

```perl
my $port = $client->port;
$client  = $client->port(1234)
```

Port on which RabbitMQ server listens for new connections.
Defaults to `5672`, which is standard RabbitMQ server listen port.

## vhost

```perl
my $vhost = $client->vhost;
$client  = $client->vhost('/')
```

RabbitMQ virtual server to user. Default is `/`.

## params

```perl
my $params = $client->params;
$client  = $client->params(Mojo::Parameters->new('verify=1'))
```

Sets additional parameters for connection. Default is not defined.

For list of supported parameters see ["SUPPORTED QUERY PARAMETERS"](#supported-query-parameters).

## url

```perl
my $url = $client->url;
$client = $client->url('amqp://...');
```

Sets all connection parameters in one string, according to specification from
[https://www.rabbitmq.com/uri-spec.html](https://www.rabbitmq.com/uri-spec.html).

```perl
amqp_URI       = "amqp[s]://" amqp_authority [ "/" vhost ] [ "?" query ]

amqp_authority = [ amqp_userinfo "@" ] host [ ":" port ]

amqp_userinfo  = username [ ":" password ]

username       = *( unreserved / pct-encoded / sub-delims )

password       = *( unreserved / pct-encoded / sub-delims )

vhost          = segment
```

## heartbeat\_timeout

```perl
my $timeout = $client->heartbeat_timeout;
$client     = $client->heartbeat_timeout(180);
```

Heartbeats are use to monitor peer reachability in AMQP.
Default value is `60` seconds, if set to `0` no heartbeats will be sent.

## connect\_timeout

```perl
my $timeout = $client->connect_timeout;
$client     = $client->connect_timeout(5);
```

Connection timeout used by [Mojo::IOLoop::Client](https://metacpan.org/pod/Mojo::IOLoop::Client).
Defaults to environment variable `MOJO_CONNECT_TIMEOUT` or `10` seconds
if nothing else is set.

## max\_channels

```perl
my $max_channels = $client->max_channels;
$client          = $client->max_channels(10);
```

Maximum number of channels allowed to be active. Defaults to `0` which
means no implicit limit.

When you try to call `add_channel` over limit an `error` will be
emitted on channel saying that: _Maximum number of channels reached_.

# STATIC METHODS

## consumer

```perl
my $client = Mojo::RabbitMQ::Client->consumer(...)
```

Shortcut for creating [Mojo::RabbitMQ::Client::Consumer](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Consumer).

## publisher

```perl
my $client = Mojo::RabbitMQ::Client->publisher(...)
```

Shortcut for creating [Mojo::RabbitMQ::Client::Publisher](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Publisher).

# METHODS

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) inherits all methods from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter) and implements
the following new ones.

## connect

```
$client->connect();
```

Tries to connect to RabbitMQ server and negotiate AMQP protocol.

## close

```
$client->close();
```

## param

```perl
my $param = $client->param('name');
$client   = $client->param(name => 'value');
```

## add\_channel

```perl
my $channel = Mojo::RabbitMQ::Client::Channel->new();
...
$channel    = $client->add_channel($channel);
$channel->open;
```

## open\_channel

```perl
my $channel = Mojo::RabbitMQ::Client::Channel->new();
...
$client->open_channel($channel);
```

## delete\_channel

```perl
my $removed = $client->delete_channel($channel->id);
```

# SUPPORTED QUERY PARAMETERS

There's no formal specification, nevertheless a list of common parameters
recognized by officially supported RabbitMQ clients is maintained here:
[https://www.rabbitmq.com/uri-query-parameters.html](https://www.rabbitmq.com/uri-query-parameters.html).

Some shortcuts are also supported, you'll find them in parenthesis.

Aliases are less significant, so when both are specified only primary
value will be used.

## cacertfile (_ca_)

Path to Certificate Authority file for TLS.

## certfile (_cert_)

Path to the client certificate file for TLS.

## keyfile (_key_)

Path to the client certificate private key file for TLS.

## fail\_if\_no\_peer\_cert (_verify_)

TLS verification mode, defaults to 0x01 on the client-side if a certificate
authority file has been provided, or 0x00 otherwise.

## auth\_mechanism

Currently only AMQPLAIN is supported, **so this parameter is ignored**.

## heartbeat

Sets requested heartbeat timeout, just like `heartbeat_timeout` attribute.

## connection\_timeout (_timeout_)

Sets connection timeout - see [connection\_timeout](https://metacpan.org/pod/connection_timeout) attribute.

## channel\_max

Sets maximum number of channels - see [max\_channels](https://metacpan.org/pod/max_channels) attribute.

# SEE ALSO

[Mojo::RabbitMQ::Client::Channel](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Channel), [Mojo::RabbitMQ::Client::Consumer](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Consumer), [Mojo::RabbitMQ::Client::Publisher](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Publisher)

# COPYRIGHT AND LICENSE

Copyright (C) 2015-2019, Sebastian Podjasek and others

Based on [AnyEvent::RabbitMQ](https://metacpan.org/pod/AnyEvent::RabbitMQ) - Copyright (C) 2010 Masahito Ikuta, maintained by `bobtfish@bobtfish.net`

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

Contains AMQP specification (`shared/amqp0-9-1.stripped.extended.xml`) licensed under BSD-style license.
