use strict;
use Test::More tests => 5;
use Test::Exception;

use_ok 'Mojo::RabbitMQ::Client';

my $client = Mojo::RabbitMQ::Client->new();

throws_ok { $client->consumer() } qr/is a static method/, 'calling consumer on instance goes fatal';
throws_ok { $client->publisher() } qr/is a static method/, 'calling publisher on instance goes fatal';

lives_and { isa_ok Mojo::RabbitMQ::Client->consumer(), 'Mojo::RabbitMQ::Client::Consumer' }, 'called consumer on package, should live';
lives_and { isa_ok Mojo::RabbitMQ::Client->publisher(), 'Mojo::RabbitMQ::Client::Publisher' }, 'called publisher on package, should live';
