use strict;
use Test::More tests => 7;

BEGIN {
    use_ok 'Mojo::RabbitMQ::Client';
    use_ok 'Mojo::RabbitMQ::Client::Channel';
    use_ok 'Mojo::RabbitMQ::Client::Consumer';
    use_ok 'Mojo::RabbitMQ::Client::LocalQueue';
    use_ok 'Mojo::RabbitMQ::Client::Method';
    use_ok 'Mojo::RabbitMQ::Client::Method::Publish';
    use_ok 'Mojo::RabbitMQ::Client::Publisher';
}
