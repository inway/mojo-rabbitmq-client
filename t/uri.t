use strict;
use Test::More tests => 94;

my @order = qw(tls user pass host port vhost param);
my @tests = ();

# Basic tests taken from https://www.rabbitmq.com/uri-spec.html
push @tests,
  [
  'amqp://user:pass@host:10000/vhost',
  0, "user", "pass", "host", "10000", "vhost"
  ],
  [
  'amqp://user%61:%61pass@ho%61st:10000/v%2fhost',
  0, "usera", "apass", "hoast", "10000", "v/host"
  ],
  ['amqp://',           0, undef,  undef,  "localhost", "5672",  "/"],
  ['amqp://:@/',        0, "",     "",     "localhost", "5672",  "/"],
  ['amqp://user@',      0, "user", undef,  "localhost", "5672",  "/"],
  ['amqp://user:pass@', 0, "user", "pass", "localhost", "5672",  "/"],
  ['amqp://host',       0, undef,  undef,  "host",      "5672",  "/"],
  ['amqp://:10000',     0, undef,  undef,  "localhost", "10000", "/"],
  ['amqp:///vhost',     0, undef,  undef,  "localhost", "5672",  "vhost"],
  ['amqp://host/',      0, undef,  undef,  "host",      "5672",  "/"],
  ['amqp://host/%2f',   0, undef,  undef,  "host",      "5672",  "/"],
  ['amqp://host///',    0, undef,  undef,  "host",      "5672",  "//"],
  ['amqp://[::1]',      0, undef,  undef,  "[::1]",     "5672",  "/"];

use_ok 'Mojo::RabbitMQ::Client';

foreach my $t (@tests) {
  my $idx = 0;
  my $url = shift @$t;

  my $client = Mojo::RabbitMQ::Client->new(url => $url);

  for my $v (@$t) {
    my $attr = $order[$idx];
    if (ref($v) eq 'HASH') {
      foreach my $k (keys %$v) {
        my $x = $v->{$k};
        is($client->$attr($k), $x,
          "expect $attr($k) to be " . ($x // '(undefined)') . " from $url");
      }
    }
    else {
      is($client->$attr(), $v,
        "expect $attr to be " . ($v // '(undefined)') . " from $url");
    }

    $idx++;
  }
}
