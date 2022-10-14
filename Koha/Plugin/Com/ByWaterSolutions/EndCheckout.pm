package Koha::Plugin::Com::ByWaterSolutions::EndCheckout;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use C4::Circulation;
use C4::Log;

use Koha::Items;

use Cwd qw(abs_path);
use Data::Dumper;

use Array::Utils qw( array_minus );

## Here we set our plugin version
our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Koha End Checkout Plugin',
    author          => 'Nick Clemens',
    date_authored   => '2022-10-14',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements an option to end a checkout'
      . 'without performing a "return" to avoid refunding lost fees or marking the item as found',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    if ( $cgi->param('submitted') ) {
        $self->tool_step2();
    }
    elsif ( $cgi->param('confirmed') ) {
        $self->tool_step3();
    } else {
        $self->tool_step1();
    }

}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    return 1;

}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;
}


sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step1.tt' });

    $self->output_html( $template->output() );
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step2.tt' });
    my @barcodes = split /\s\n/, scalar $cgi->param('barcodes');
    chomp @barcodes;
    my $items = Koha::Items->search({
        barcode => { -in => \@barcodes }
    },{
        prefetch => [ { 'issue' => 'patron' },'biblio']
    });

    my @seen;
    my @problem_barcodes;
    my @items_to_return;
    while( my $item = $items->next ){
        push @seen, $item->barcode;
        if( $item->checkout ){
            push @items_to_return, $item;
        } else {
            push @problem_barcodes, { barcode => $item->barcode, problem => "Item not checked out" };
        }
    }
    
    my @not_seen = array_minus(@barcodes, @seen);
    foreach my $not_seen (@not_seen){
        push @problem_barcodes, { barcode => $not_seen, problem => "Barcode not found" };
    }


    $template->param( 'problem_barcodes' => \@problem_barcodes );
    $template->param( 'return_items' => \@items_to_return );

    $self->output_html( $template->output() );
}

sub tool_step3 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step3.tt' });
    my @itemnumbers = $cgi->multi_param('return_items');
    my $items = Koha::Items->search({
        'me.itemnumber' => { -in => \@itemnumbers }
    },{
        prefetch => [ {'issue' => 'patron'}, 'biblio' ]
    });

    my @problem_barcodes;
    my @returned_items;
    while( my $item = $items->next ){
        if( $item->checkout ){
            my $checkout = $item->checkout;
            my $returned = C4::Circulation::MarkIssueReturned( $checkout->borrowernumber, $item->itemnumber, undef, $checkout->patron->privacy );
            if( $returned ){
                push @returned_items, $item;
                C4::Log::logaction("CIRCULATION","RETURN",$checkout->borrowernumber,"Return of issue:".$checkout->id." item:".$item->id." forced via EndCheckout plugin");
            } else {
                push @problem_barcodes, { barcode => $item->barcode, problem => "There was a problem returning this item" };
            }
        } else {
            push @problem_barcodes, { barcode => $item->barcode, problem => "This item was not checked out" };
        }
    }
    

    $template->param( 'problem_barcodes' => \@problem_barcodes );
    $template->param( 'returned_items' => \@returned_items );

    $self->output_html( $template->output() );
}

1;
