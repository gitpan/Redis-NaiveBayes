package Redis::NaiveBayes;
# ABSTRACT: A generic Redis-backed NaiveBayes implementation
$Redis::NaiveBayes::VERSION = '0.0.4';

use strict;
use warnings;
use List::Util qw(sum reduce);

use Redis;

use constant {
    LABELS => 'labels',
};

# Lua scripts
my $LUA_FLUSH_FMT = q{
    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    for _, member in ipairs(redis.call('smembers', labels_key)) do
        redis.call('del', namespace .. member)
        redis.call('del', namespace .. 'tally_for:' .. member)
    end
    redis.call('del', labels_key);
};

my $LUA_TRAIN_FMT = q{
    -- ARGV:
    --   1: raw label name being trained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    local label      = namespace .. ARGV[1]
    local tally_key  = namespace .. 'tally_for:' .. ARGV[1]
    local num_tokens = ARGV[2]
    local tot_added  = 0

    redis.call('sadd', labels_key, ARGV[1])

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            redis.call('hincrby', label, token, ARGV[index + num_tokens])
            tot_added = tot_added + ARGV[index + num_tokens]
        end
    end

    local old_tally = redis.call('get', tally_key);
    if (not old_tally) then
        old_tally = 0
    end

    redis.call('set', tally_key, old_tally + tot_added)
};

my $LUA_UNTRAIN_FMT = q{
    -- ARGV:
    --   1: raw label name being untrained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    local label      = namespace .. ARGV[1]
    local tally_key  = namespace .. 'tally_for:' .. ARGV[1]
    local num_tokens = ARGV[2]

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            local current = redis.call('hget', label, token);

            if (current and current - ARGV[index + num_tokens] > 0) then
                redis.call('hincrby', label, token, -1 * ARGV[index + num_tokens])
            else
                redis.call('hdel', label, token)
            end
        end
    end

    local tally = 0
    for _, value in ipairs(redis.call('hvals', label)) do
        tally = tally + value
    end

    if tally <= 0 then
        redis.call('del', label)
        redis.call('srem', labels_key, ARGV[1])
        redis.call('del', tally_key)
    else
        redis.call('set', tally_key, tally)
    end
};

my $_LUA_CALCULATE_SCORES = q{
    -- ARGV
    --   1: correction
    --   2: number of tokens
    --   3-X: tokens
    --   X+1-N: values for each token
    -- FIXME: I'm ignoring the scores per token on purpose for now

    local namespace  = '%s'
    local labels_key = namespace .. '%s'
    local correction = ARGV[1]
    local num_tokens = ARGV[2]

    local scores = {}

    for index, raw_label in ipairs(redis.call('smembers', labels_key)) do
        local label = namespace .. raw_label

        local tally = tonumber(redis.call('get', namespace .. 'tally_for:' .. raw_label))

        if (tally and tally > 0) then
            scores[raw_label] = 0.0

            for idx, token in ipairs(ARGV) do
                if idx > num_tokens + 2 then
                    break
                end

                if idx > 2 then
                    local score = redis.call('hget', label, token)

                    if (not score or score == 0) then
                        score = correction
                    end

                    scores[raw_label] = scores[raw_label] + math.log(score / tally)
                end
            end
        end
    end
};

my $LUA_SCORES_FMT = qq{
    $_LUA_CALCULATE_SCORES

    local return_crap = {}
    local index = 1
    for key, value in pairs(scores) do
        return_crap[index] = key
        return_crap[index+1] = value
        index = index + 2
    end

    return return_crap;
};

my $LUA_CLASSIFY_FMT = qq{
    $_LUA_CALCULATE_SCORES

    local best_label = nil
    local best_score = nil
    for label, score in pairs(scores) do
        if (best_score == nil or best_score < score) then
            best_label = label
            best_score = score
        end
    end

    return best_label
};


sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{redis}      = $args{redis}      || Redis->new(%args);
    $self->{correction} = $args{correction} || 0.001;
    $self->{namespace}  = $args{namespace}  or die "Missing namespace";
    $self->{tokenizer}  = $args{tokenizer}  or die "Missing tokenizer";

    $self->_load_scripts;

    return $self;
}

sub _redis_script_load {
    my ($self, $script_fmt, @args) = @_;

    my ($sha1) = $self->{redis}->script_load(sprintf($script_fmt, $self->{namespace}, LABELS, @args));

    return $sha1;
}

sub _load_scripts {
    my ($self) = @_;

    $self->{scripts} = {};

    $self->{scripts}->{flush} = $self->_redis_script_load($LUA_FLUSH_FMT);
    $self->{scripts}->{train} = $self->_redis_script_load($LUA_TRAIN_FMT);
    $self->{scripts}->{untrain} = $self->_redis_script_load($LUA_UNTRAIN_FMT);
    $self->{scripts}->{scores} = $self->_redis_script_load($LUA_SCORES_FMT);
    $self->{scripts}->{classify} = $self->_redis_script_load($LUA_CLASSIFY_FMT);
}

sub _exec {
    my ($self, $command, $key, @rest) = @_;

    return $self->{redis}->$command($self->{namespace} . $key, @rest);
}

sub _run_script {
    my ($self, $script, $numkeys, @rest) = @_;

    $numkeys ||= 0;
    my $sha1 = $self->{scripts}->{$script} or die "Script wasn't loaded: '$script'";

    $self->{redis}->evalsha($sha1, $numkeys, @rest);
}


sub flush {
    my ($self) = @_;

    $self->_run_script('flush');
}

sub _mrproper {
    my ($self) = @_;

    my @keys = $self->{redis}->keys($self->{namespace} . '*');
    $self->{redis}->del(@keys) if @keys;
}

sub _train {
    my ($self, $label, $item, $script) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @argv = ($label, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences);

    $self->_run_script($script, 0, @argv);

    return $occurrences;
}


sub train {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'train');
}


sub untrain {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'untrain');
}


sub classify {
    my ($self, $item) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @argv = ($self->{correction}, scalar keys %$occurrences, keys %$occurrences, values %$occurrences);

    my $best_label = $self->_run_script('classify', 0, @argv);

    return $best_label;
}


sub scores {
    my ($self, $item) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @argv = ($self->{correction}, scalar keys %$occurrences, keys %$occurrences, values %$occurrences);

    my %scores = $self->_run_script('scores', 0, @argv);

    return \%scores;
}

sub _labels {
    my ($self) = @_;

    return $self->_exec('smembers', LABELS);
}

sub _priors {
    my ($self, $label) = @_;

    my %data = $self->_exec('hgetall', $label);
    return { %data };
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Redis::NaiveBayes - A generic Redis-backed NaiveBayes implementation

=head1 VERSION

version 0.0.4

=head1 SYNOPSIS

    my $tokenizer = sub {
        my $input = shift;

        my %occurs;
        $occurs{$_}++ for split(/\s/, lc $input);

        return \%occurs;
    };

    my $bayes = Redis::NaiveBayes->new(
        namespace => 'playground:',
        tokenizer => \&tokenizer,
    );

=head1 DESCRIPTION

This distribution provides a very simple NaiveBayes classifier
backed by a Redis instance. It uses the evalsha functionality
available since Redis 2.6.0 to try to speed things up while
avoiding some obvious race conditions during the untrain() phase.

The goal of Redis::NaiveBayes is to keep dependencies at
minimum while being as generic as possible to allow any sort
of usage. By design, it doesn't provide any sort of tokenization
nor filtering out of the box.

=head1 METHODS

=head2 new

    my $bayes = Redis::NaiveBayes->new(
        namespace  => 'playground:',
        tokenizer  => \&tokenizer,
        correction => 0.1,
        redis      => $redis_instance,
    );

Instantiates a L<Redis::NaiveBayes> instance using the provided
C<correction>, C<namespace> and C<tokenizers>.

If provided, it also uses a L<Redis> instance (C<redis> parameter)
instead of instantiating one by itself.

A tokenizer is any subroutine that returns a HASHREF of occurrences
in the item provided for train()ining or classify()ing.

=head2 flush

    $bayes->flush;

Cleanup all the possible keys this classifier instance could've
touched. If you want to clean everything under the provided namespace,
call _mrproper() instead, but beware that it will delete all the
keys that match C<namespace*>.

=head2 train

    $bayes->train("ham", "this is a good message");
    $bayes->train("spam", "price from Nigeria needs your help");

Trains as a label ("ham") the given item. The item can be any arbitrary
structure as long as the provided C<tokenizer> understands it.

=head2 untrain

    $bayes->untrain("ham", "I don't thing this message is good anymore")

The opposite of train().

=head2 classify

    my $label = $bayes->classify("Nigeria needs help");
    >>> "spam"

Gets the most probable category the provided item in is.

=head2 scores

    my $scores = $bayes->scores("any sort of message");

Returns a HASHREF with the scores for each of the labels known by the model

=head1 NOTES

This module is heavilly inspired by the Python implementation
available at https://github.com/jart/redisbayes - the main
difference, besides the obvious language choice, is that
Redis::NaiveBayes focuses on being generic and minimizing
the number of roundtrips to Redis.

=head1 TODO

=over

=item Add support for additive smoothing

=back

=head1 SEE ALSO

L<Redis>, L<Redis::Bayes>, L<Algorithm::NaiveBayes>

=head1 AUTHORS

=over 4

=item *

Caio Romão <cpan@caioromao.com>

=item *

Stanislaw Pusep <stas@sysd.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Caio Romão.

This is free software, licensed under:

  The MIT (X11) License

=cut
