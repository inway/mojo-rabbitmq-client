use strict;
use Test::More tests => 7;

use_ok $_ for qw(
  Mojo::RabbitMQ::Client
  Mojo::RabbitMQ::Client::Channel
  Mojo::RabbitMQ::Client::Consumer
  Mojo::RabbitMQ::Client::LocalQueue
  Mojo::RabbitMQ::Client::Method
  Mojo::RabbitMQ::Client::Method::Publish
  Mojo::RabbitMQ::Client::Publisher
);
