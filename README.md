[![Build Status](https://travis-ci.org/inway/mojo-rabbitmq-client.svg?branch=master)](https://travis-ci.org/inway/mojo-rabbitmq-client)
# NAME

Mojo::RabbitMQ::Client - Mojo::IOLoop based RabbitMQ client

# SYNOPSIS

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

## CONSUMER

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

    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

## PUBLISHER

    use Mojo::RabbitMQ::Client;
    my $publisher = Mojo::RabbitMQ::Client->publisher(
      url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo'
    );

    $publisher->catch(sub { die "Some error caught in Publisher" } );
    $publisher->on('success' => sub { say "Publisher ready" });

    $publisher->publish('plain text');
    $publisher->publish({encode => { to => 'json'}});

    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

# DESCRIPTION

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) is a rewrite of [AnyEvent::RabbitMQ](https://metacpan.org/pod/AnyEvent::RabbitMQ) to work on top of [Mojo::IOLoop](https://metacpan.org/pod/Mojo::IOLoop).

# EVENTS

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) inherits all events from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter) and can emit the
following new ones.

## connect

    $client->on(connect => sub {
      my ($client, $stream) = @_;
      ...
    });

Emitted when TCP/IP connection with RabbitMQ server is established.

## open

    $client->on(open => sub {
      my ($client) = @_;
      ...
    });

Emitted AMQP protocol Connection.Open-Ok method is received.

## close

    $client->on(close => sub {
      my ($client) = @_;
      ...
    });

Emitted on reception of Connection.Close-Ok method.

## disconnect

    $client->on(close => sub {
      my ($client) = @_;
      ...
    });

Emitted when TCP/IP connection gets disconnected.

# ATTRIBUTES

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) has following attributes.

## url

    my $url = $client->url;
    $client->url('rabbitmq://...');

## heartbeat\_timeout

    my $timeout = $client->heartbeat_timeout;
    $client->heartbeat_timeout(180);

# METHODS

[Mojo::RabbitMQ::Client](https://metacpan.org/pod/Mojo::RabbitMQ::Client) inherits all methods from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter) and implements
the following new ones.

## connect

    $client->connect();

Tries to connect to RabbitMQ server and negotiate AMQP protocol.

## close

    $client->close();

## open\_channel

    my $channel = Mojo::RabbitMQ::Client::Channel->new();
    ...
    $client->open_channel($channel);

## delete\_channel

    my $removed = $client->delete_channel($channel->id);

# SEE ALSO

[Mojo::RabbitMQ::Client::Channel](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Channel), [Mojo::RabbitMQ::Client::Consumer](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Consumer), [Mojo::RabbitMQ::Client::Publisher](https://metacpan.org/pod/Mojo::RabbitMQ::Client::Publisher)

# COPYRIGHT AND LICENSE

Copyright (C) 2015-2016, Sebastian Podjasek and others

Based on [AnyEvent::RabbitMQ](https://metacpan.org/pod/AnyEvent::RabbitMQ) - Copyright (C) 2010 Masahito Ikuta, maintained by `bobtfish@bobtfish.net`

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.
