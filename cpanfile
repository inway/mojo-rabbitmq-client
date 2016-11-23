requires 'perl', '5.008001';
requires 'Mojolicious', '6.10';
requires 'Net::AMQP', '0.06';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Exception', '0.43';
};

