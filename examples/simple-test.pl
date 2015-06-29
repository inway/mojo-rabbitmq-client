#!/usr/bin/perl
use Mojo::Base -strict;
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::RabbitMQ::Client;

my $loop = Mojo::IOLoop->singleton;
my $log  = Mojo::Log->new(threshold => 'trace');
my $amqp = Mojo::RabbitMQ::Client->new(
  url => 'rabbitmq://guest:guest@127.0.0.1:5672/');

$amqp->catch(sub { $log->error("Error connecting to RabbitMQ"); });
$amqp->on(connect => sub { $log->debug("Connected to RabbitMQ host"); });
$amqp->on(
  open => sub {
    my ($self) = @_;

    $log->debug("Openned connection to RabbitMQ host");

    my $channel = Mojo::RabbitMQ::Channel->new();
    $channel->on(
      open => sub {
        my ($channel) = @_;

        $log->debug("Opened channel to RabbitMQ host");

        $log->debug("Publish sample message to `test_queue` queue");
        my $publish = $channel->publish(
          exchange    => 'test',
          routing_key => 'test_queue',
          body        => 'Test message',
          mandatory   => 0,
          immediate   => 0,
          header      => {}
        );
        $publish->catch(sub { $log->debug("Message publish failure"); });
        $publish->on(success => sub { $log->debug("Message published"); });
        $publish->on(return => sub { $log->debug("Message returned to us"); });
        $publish->deliver();

        my $consumer = $channel->consume(queue => 'test_queue',);
        $consumer->on(success => sub { $log->debug("Consumed") });
        $consumer->on(message => sub { $log->debug("Received a message") });
        $consumer->catch(sub { $log->debug("Error while consuming queue") });
        $consumer->deliver;
      }
    );
    $channel->catch(
      sub { $log->debug("Failed to open channel to RabbitMQ host"); });

    $self->open_channel($channel);
  }
);
$amqp->on(close      => sub { $log->error("RabbitMQ connection closed"); });
$amqp->on(disconnect => sub { $log->error("RabbitMQ disconnected"); });
$amqp->connect();

$loop->start unless $loop->is_running;
