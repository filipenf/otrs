#!/usr/bin/perl
# --
# Copyright (C) 2001-2015 OTRS AG, http://otrs.com/
# --
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU AFFERO General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
# or see http://www.gnu.org/licenses/agpl.txt.
# --

use strict;
use warnings;

# use ../ as lib location
use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . '/Kernel/cpan-lib';

use Getopt::Std qw();
use Kernel::Config;
use Kernel::System::ObjectManager;
use Kernel::System::SysConfig;
use Kernel::System::Cache;
use Kernel::System::VariableCheck qw(:all);

local $Kernel::OM = Kernel::System::ObjectManager->new(
    'Kernel::System::Log' => {
        LogPrefix => 'OTRS-DBUpdate-to-5.pl',
    },
);

{

    # get options
    my %Opts;
    Getopt::Std::getopt( 'h', \%Opts );

    if ( exists $Opts{h} ) {
        print <<"EOF";

DBUpdate-to-5.pl - Upgrade script for OTRS 4 to 5 migration.
Copyright (C) 2001-2015 OTRS AG, http://otrs.com/

Usage: $0 [-h]
    Options are as follows:
        -h      display this help

EOF
        exit 1;
    }

    # UID check if not on Windows
    if ( $^O ne 'MSWin32' && $> == 0 ) {    # $EFFECTIVE_USER_ID
        die "
Cannot run this program as root.
Please run it as the 'otrs' user or with the help of su:
    su -c \"$0\" -s /bin/bash otrs
";
    }

    # enable autoflushing of STDOUT
    $| = 1;                                 ## no critic

    # define tasks and their mesages
    my @Tasks = (
        {
            Message => 'Refresh configuration cache',
            Command => \&RebuildConfig,
        },
        {
            Message => 'Check framework version',
            Command => \&_CheckFrameworkVersion,
        },
        {
            Message => 'Migrate Output configurations to the new module locations',
            Command => \&_MigrateConfigs,
        },
        {
            Message => 'Clean up the cache',
            Command => sub {
                $Kernel::OM->Get('Kernel::System::Cache')->CleanUp();
            },
        },
        {
            Message => 'Refresh configuration cache another time',
            Command => \&RebuildConfig,
        },
    );

    print "\nMigration started...\n\n";

    # get the number of total steps
    my $Steps = scalar @Tasks;
    my $Step  = 1;
    for my $Task (@Tasks) {

        # show task message
        print "Step $Step of $Steps: $Task->{Message}...";

        # run task command
        if ( &{ $Task->{Command} } ) {
            print "done.\n\n";
        }
        else {
            print "error.\n\n";
            die;
        }

        $Step++;
    }

    print "Migration completed!\n";

    exit 0;
}

=item RebuildConfig()

refreshes the configuration to make sure that a ZZZAAuto.pm is present
after the upgrade.

    RebuildConfig();

=cut

sub RebuildConfig {

    my $SysConfigObject = Kernel::System::SysConfig->new();

    # Rebuild ZZZAAuto.pm with current values
    if ( !$SysConfigObject->WriteDefault() ) {
        die "Error: Can't write default config files!";
    }

    # Force a reload of ZZZAuto.pm and ZZZAAuto.pm to get the new values
    for my $Module ( sort keys %INC ) {
        if ( $Module =~ m/ZZZAA?uto\.pm$/ ) {
            delete $INC{$Module};
        }
    }

    # reload config object
    print "\nIf you see warnings about 'Subroutine Load redefined', that's fine, no need to worry!\n";

    # create common objects with new default config
    $Kernel::OM->ObjectsDiscard();

    return 1;
}

=item _CheckFrameworkVersion()

Check if framework it's the correct one for Dynamic Fields migration.

    _CheckFrameworkVersion();

=cut

sub _CheckFrameworkVersion {
    my $Home = $Kernel::OM->Get('Kernel::Config')->Get('Home');

    # load RELEASE file
    if ( -e !"$Home/RELEASE" ) {
        die "Error: $Home/RELEASE does not exist!";
    }
    my $ProductName;
    my $Version;
    if ( open( my $Product, '<', "$Home/RELEASE" ) ) {    ## no critic
        while (<$Product>) {

            # filtering of comment lines
            if ( $_ !~ /^#/ ) {
                if ( $_ =~ /^PRODUCT\s{0,2}=\s{0,2}(.*)\s{0,2}$/i ) {
                    $ProductName = $1;
                }
                elsif ( $_ =~ /^VERSION\s{0,2}=\s{0,2}(.*)\s{0,2}$/i ) {
                    $Version = $1;
                }
            }
        }
        close($Product);
    }
    else {
        die "Error: Can't read $Home/RELEASE: $!";
    }

    if ( $ProductName ne 'OTRS' ) {
        die "Error: No OTRS system found"
    }
    if ( $Version !~ /^5\.0(.*)$/ ) {

        die "Error: You are trying to run this script on the wrong framework version $Version!"
    }

    return 1;
}

=item _MigrateConfigs()

Change toolbar configurations to match the new module location.

    _MigrateConfigs();

=cut

sub _MigrateConfigs {

    # get needed objects
    my $ConfigObject    = $Kernel::OM->Get('Kernel::Config');
    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');

    print "\n--- Toolbar modules...";

    # Toolbar Modules
    my $Setting = $ConfigObject->Get('Frontend::ToolBarModule');

    TOOLBARMODULE:
    for my $ToolbarModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$ToolbarModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::ToolBar(\w+)} ) {
            next TOOLBARMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::ToolBar(\w+)}{Kernel::Output::HTML::ToolBar::$1}xmsg;
        $Setting->{$ToolbarModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Frontend::ToolBarModule###' . $ToolbarModule,
            Value => $Setting->{$ToolbarModule},
        );
    }

    print "...done.\n";
    print "--- Ticket menu modules...";

    # Ticket Menu Modules
    $Setting = $ConfigObject->Get('Ticket::Frontend::MenuModule');

    MENUMODULE:
    for my $MenuModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$MenuModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::TicketMenu(\w+)} ) {
            next MENUMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::TicketMenu(\w+)}{Kernel::Output::HTML::TicketMenu::$1}xmsg;
        $Setting->{$MenuModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Ticket::Frontend::MenuModule###' . $MenuModule,
            Value => $Setting->{$MenuModule},
        );
    }

    print "...done.\n";
    print "--- Ticket overview menu modules...";

    # Ticket Menu Modules
    $Setting = $ConfigObject->Get('Ticket::Frontend::OverviewMenuModule');

    MENUMODULE:
    for my $MenuModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$MenuModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::TicketOverviewMenu(\w+)} ) {
            next MENUMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::TicketOverviewMenu(\w+)}{Kernel::Output::HTML::TicketOverviewMenu::$1}xmsg;
        $Setting->{$MenuModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Ticket::Frontend::OverviewMenuModule###' . $MenuModule,
            Value => $Setting->{$MenuModule},
        );
    }

    print "...done.\n";
    print "--- Ticket overview modules...";

    # Ticket Menu Modules
    $Setting = $ConfigObject->Get('Ticket::Frontend::Overview');

    OVERVIEWMODULE:
    for my $OverviewModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$OverviewModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::TicketOverview(\w+)} ) {
            next OVERVIEWMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::TicketOverview(\w+)}{Kernel::Output::HTML::TicketOverview::$1}xmsg;
        $Setting->{$OverviewModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Ticket::Frontend::Overview###' . $OverviewModule,
            Value => $Setting->{$OverviewModule},
        );
    }

    print "...done.\n";
    print "--- Preferences group modules...";

    # Preferences groups
    $Setting = $ConfigObject->Get('PreferencesGroups');

    PREFERENCEMODULE:
    for my $PreferenceModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$PreferenceModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::Preferences(\w+)} ) {
            next PREFERENCEMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::Preferences(\w+)}{Kernel::Output::HTML::Preferences::$1}xmsg;
        $Setting->{$PreferenceModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'PreferencesGroups###' . $PreferenceModule,
            Value => $Setting->{$PreferenceModule},
        );
    }

    print "...done.\n";
    print "--- SLA/Service/Queue preference modules...";

    # SLA, Service and Queue preferences
    for my $Type (qw(SLA Service Queue)) {

        $Setting = $ConfigObject->Get( $Type . 'Preferences' );

        MODULE:
        for my $PreferenceModule ( sort keys %{$Setting} ) {

            # update module location
            my $Module = $Setting->{$PreferenceModule}->{'Module'};
            my $Regex  = 'Kernel::Output::HTML::' . $Type . 'Preferences(\w+)';
            if ( $Module !~ m{$Regex} ) {
                next MODULE;
            }

            $Module =~ s{$Regex}{Kernel::Output::HTML::${Type}Preferences::$1}xmsg;
            $Setting->{$PreferenceModule}->{'Module'} = $Module;

            # set new setting,
            my $Success = $SysConfigObject->ConfigItemUpdate(
                Valid => 1,
                Key   => $Type . 'Preferences###' . $PreferenceModule,
                Value => $Setting->{$PreferenceModule},
            );
        }
    }

    print "...done.\n";
    print "--- Article pre view modules...";

    # Article pre view modules
    $Setting = $ConfigObject->Get('Ticket::Frontend::ArticlePreViewModule');

    ARTICLEMODULE:
    for my $ArticlePreViewModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$ArticlePreViewModule}->{'Module'};
        if ( $Module !~ m{Kernel::Output::HTML::ArticleCheck(\w+)} ) {
            next ARTICLEMODULE;
        }

        $Module =~ s{Kernel::Output::HTML::ArticleCheck(\w+)}{Kernel::Output::HTML::ArticleCheck::$1}xmsg;
        $Setting->{$ArticlePreViewModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Ticket::Frontend::ArticlePreViewModule###' . $ArticlePreViewModule,
            Value => $Setting->{$ArticlePreViewModule},
        );
    }

    print "...done.\n";
    print "--- NavBar menu modules...";

    # NavBar menu modules
    my @NavBarTypes = (
        {
            Path => 'Frontend::NavBarModule',
        },
        {
            Path => 'CustomerFrontend::NavBarModule',
        },
    );

    for my $Type (@NavBarTypes) {

        $Setting = $ConfigObject->Get( $Type->{Path} );

        NAVBARMODULE:
        for my $NavBarModule ( sort keys %{$Setting} ) {

            # update module location
            my $Module = $Setting->{$NavBarModule}->{'Module'};

            if ( $Module !~ m{Kernel::Output::HTML::NavBar(\w+)} ) {
                next NAVBARMODULE;
            }

            $Module =~ s{Kernel::Output::HTML::NavBar(\w+)}{Kernel::Output::HTML::NavBar::$1}xmsg;
            $Setting->{$NavBarModule}->{'Module'} = $Module;

            # set new setting,
            my $Success = $SysConfigObject->ConfigItemUpdate(
                Valid => 1,
                Key   => $Type->{Path} . '###' . $NavBarModule,
                Value => $Setting->{$NavBarModule},
            );
        }
    }

    print "...done.\n";
    print "--- NavBar ModuleAdmin modules...";

    # NavBar module admin
    $Setting = $ConfigObject->Get('Frontend::Module');

    MODULEADMIN:
    for my $ModuleAdmin ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$ModuleAdmin}->{NavBarModule}->{'Module'} // '';

        if ( $Module !~ m{Kernel::Output::HTML::NavBar(\w+)} ) {
            next MODULEADMIN;
        }
        $Setting->{$ModuleAdmin}->{NavBarModule}->{'Module'} = "Kernel::Output::HTML::NavBar::ModuleAdmin";

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Frontend::Module###' . $ModuleAdmin,
            Value => $Setting->{$ModuleAdmin},
        );
    }

    print "...done.\n";
    print "--- Dashboard modules...";

    # Dashboard modules
    my @DashboardTypes = (
        {
            Path => 'DashboardBackend',
        },
        {
            Path => 'AgentCustomerInformationCenter::Backend',
        },
    );

    for my $Type (@DashboardTypes) {

        $Setting = $ConfigObject->Get( $Type->{Path} );

        DASHBOARDMODULE:
        for my $DashboardModule ( sort keys %{$Setting} ) {

            # update module location
            my $Module = $Setting->{$DashboardModule}->{'Module'} // '';

            if ( $Module !~ m{Kernel::Output::HTML::Dashboard(\w+)} ) {
                next DASHBOARDMODULE;
            }
            $Module =~ s{Kernel::Output::HTML::Dashboard(\w+)}{Kernel::Output::HTML::Dashboard::$1}xmsg;
            $Setting->{$DashboardModule}->{'Module'} = $Module;

            # set new setting,
            my $Success = $SysConfigObject->ConfigItemUpdate(
                Valid => 1,
                Key   => $Type->{Path} . '###' . $DashboardModule,
                Value => $Setting->{$DashboardModule},
            );
        }
    }

    print "...done.\n";
    print "--- Customer user generic modules...";

    # customer user generic module
    $Setting = $ConfigObject->Get('Frontend::CustomerUser::Item');

    CUSTOMERUSERGENERICMODULE:
    for my $CustomerUserGenericModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$CustomerUserGenericModule}->{'Module'} // '';

        if ( $Module !~ m{Kernel::Output::HTML::CustomerUser(\w+)} ) {
            next CUSTOMERUSERGENERICMODULE;
        }
        $Module =~ s{Kernel::Output::HTML::CustomerUser(\w+)}{Kernel::Output::HTML::CustomerUser::$1}xmsg;
        $Setting->{$CustomerUserGenericModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Frontend::CustomerUser::Item###' . $CustomerUserGenericModule,
            Value => $Setting->{$CustomerUserGenericModule},
        );
    }

    # set new setting for CustomerNewTicketQueueSelectionGeneric
    my $Success = $SysConfigObject->ConfigItemUpdate(
        Valid => 2,
        Key   => 'CustomerPanel::NewTicketQueueSelectionModule',
        Value => 'Kernel::Output::HTML::CustomerNewTicket::QueueSelectionGeneric',
    );

    print "...done.\n";
    print "--- FilterText modules...";

    # output filter module
    $Setting = $ConfigObject->Get('Frontend::Output::FilterText');

    FILTERTEXTMODULE:
    for my $FilterTextModule ( sort keys %{$Setting} ) {

        # update module location
        my $Module = $Setting->{$FilterTextModule}->{'Module'} // '';

        if ( $Module !~ m{Kernel::Output::HTML::OutputFilter::Text(\w+)} ) {
            next FILTERTEXTMODULE;
        }
        $Module =~ s{Kernel::Output::HTML::OutputFilter::Text(\w+)}{Kernel::Output::HTML::FilterText::$1}xmsg;
        $Setting->{$FilterTextModule}->{'Module'} = $Module;

        # set new setting,
        my $Success = $SysConfigObject->ConfigItemUpdate(
            Valid => 1,
            Key   => 'Frontend::Output::FilterText###' . $FilterTextModule,
            Value => $Setting->{$FilterTextModule},
        );
    }

    print "...done.\n";

    return 1;
}

1;
