
# Mojo::RabbitMQ::Client [![Build Status](https://travis-ci.org/InWayOpenSource/mojo-rabbitmq-client.svg?branch=master)](https://travis-ci.org/InWayOpenSource/mojo-rabbitmq-client)

This is a rewrite of great module AnyEvent::RabbitMQ to work on top Mojo::IOLoop.

## Getting started

Basic publish subscribe example is below. You can find more in 'examples' directory.

```perl
use Mojo::RabbitMQ::Client;

my $client = Mojo::RabbitMQ::Client->new(
  url => 'rabbitmq://guest:guest@127.0.0.1:5672/');

# Catch all client related errors
$client->catch(sub { warn "Some error caught in client"; $client->stop });

# When connection is in Open state, open new channel
$client->on(
  open => sub {
    my ($client) = @_;
    
    # Create a new channel with auto-assigned id
    my $channel = Mojo::RabbitMQ::Channel->new();
    
    $channel->catch(sub { warn "Error on channel received"; $client->stop });
    
    $channel->on(
      open => sub {
        my ($channel) = @_;
        
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
        $publish->deliver();
        
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
$client->start();
```
