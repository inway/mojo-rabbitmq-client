use strict;
use Test::More tests => 7;

use_ok 'Mojo::RabbitMQ::Client';

subtest 'attributes' => sub {
  plan tests => 7;

  my $c = new_ok(
    'Mojo::RabbitMQ::Client',
    [
      tls   => 0,
      user  => 'guest',
      host  => 'remote',
      port  => 16526,
      vhost => '/some/'
    ]
  );

  is($c->user,  'guest',  'user is guest');
  is($c->pass,  undef,    'no password');
  is($c->host,  'remote', 'host is remote');
  is($c->port,  16526,    'port is ok');
  is($c->vhost, '/some/', 'proper vhost name');
  isa_ok($c->params, 'Mojo::Parameters');
};

subtest 'query param aliases' => sub {
  plan tests => 6;

  my $a = new_ok(
    'Mojo::RabbitMQ::Client',
    [
      url => 'amqp:///?cacertfile=cacert&certfile=cert&keyfile=key'
        . '&fail_if_no_peer_cert=1&connection_timeout=100'
    ]
  );

  is($a->param('ca'),      'cacert', 'cacertfile aliased to ca');
  is($a->param('cert'),    'cert',   'cerfile aliased to cert');
  is($a->param('key'),     'key',    'keyfile aliased to key');
  is($a->param('verify'),  '1',      'fail_if_no_peer_cert aliased to verify');
  is($a->param('timeout'), '100',    'connection_timeout aliased to timeout');
};

subtest 'query param aliases less significant' => sub {
  plan tests => 2;

  my $a = new_ok('Mojo::RabbitMQ::Client',
    [url => 'amqp:///?cacertfile=cacert&ca=ca']);

  is($a->param('ca'), 'cacert', 'should take base value, not alias');
};

subtest 'attributes from query params' => sub {
  plan tests => 5;

  my $a = new_ok('Mojo::RabbitMQ::Client',
    [url => 'amqp://?heartbeat=180&timeout=90&channel_max=1']);

  is($a->host,              'localhost', 'need this to parse url!');
  is($a->heartbeat_timeout, 180,         'heartbeat timeout set');
  is($a->connect_timeout,   90,          'connect timeout set');
  is($a->max_channels,      1,           'max channels set');
};

subtest 'change default port for amqps scheme' => sub {
  plan tests => 6;

  my $c = new_ok('Mojo::RabbitMQ::Client', [url => 'amqps://']);

  is($c->user,  undef,       'no user');
  is($c->pass,  undef,       'no password');
  is($c->host,  'localhost', 'default host');
  is($c->port,  5671,        'changed port');
  is($c->vhost, '/',         'default vhost');
};

subtest 'keep specified port for amqps scheme' => sub {
  plan tests => 6;

  my $c = new_ok('Mojo::RabbitMQ::Client', [url => 'amqps://:15673']);

  is($c->user,  undef,       'no user');
  is($c->pass,  undef,       'no password');
  is($c->host,  'localhost', 'default host');
  is($c->port,  15673,       'changed port');
  is($c->vhost, '/',         'default vhost');
};
