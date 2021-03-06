#
# Author:: Philip (flip) Kromer (<flip@infochimps.com>)
# Copyright:: Copyright (c) 2011 Infochimps, Inc
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require_relative '../cluster_knife'

class Chef
  class Knife
    class ClusterLaunch < Knife
      include Ironfan::KnifeCommon

      deps do
        require 'time'
        require 'socket'
        Chef::Knife::ClusterBootstrap.load_deps
      end

      banner "knife cluster launch      CLUSTER[-FACET[-INDEXES]] (options) - Creates chef node and chef apiclient, pre-populates chef node, and instantiates in parallel their cloud computers. With --bootstrap flag, will ssh in to computers as they become ready and launch the bootstrap process"
      [ :ssh_port, :ssh_user, :ssh_password, :identity_file, :use_sudo,
        :prerelease, :bootstrap_version, :template_file, :distro,
        :bootstrap_runs_chef_client, :host_key_verify
      ].each do |name|
        option name, Chef::Knife::ClusterBootstrap.options[name]
      end

      option :dry_run,
        :long        => "--dry-run",
        :description => "Don't really run, just use mock calls",
        :boolean     => true,
        :default     => false
      option :force,
        :long        => "--force",
        :description => "Perform launch operations even if it may not be safe to do so. Default false",
        :boolean     => true,
        :default     => false
      option :bootstrap,
        :long        => "--[no-]bootstrap",
        :description => "Also bootstrap the launched machine (default is NOT to bootstrap)",
        :boolean     => true,
        :default     => false
      option :cloud,
        long:        "--[no-]cloud",
        description: "Look up computers on AWS cloud (default is yes, look up computers; use --no-cloud to skip)",
        default:     true,
        boolean:     true

      option :wait_ssh,
        :long        => "--[no-]wait-ssh",
        :description => "Wait for the target machine to open an ssh port",
        :boolean     => true,
        :default     => true

      def _run
        load_ironfan
        die(banner) if @name_args.empty?
        configure_dry_run

        #
        # Load the facet
        #
        full_target = get_slice(*@name_args)
        display(full_target)
        target = full_target.select(&:launchable?)

        warn_or_die_on_bogus_servers(full_target) unless full_target.select(&:bogus?).empty?

        die("", "#{ui.color("All computers are running -- not launching any.",:blue)}", "", 0) if target.empty?

        # If a bootstrap was requested, ensure that we will be able to perform the
        # bootstrap *before* trying to launch all of the servers in target. This
        # will save the user a lot of time if they've made a configuration mistake
        if config[:bootstrap]
          ensure_common_environment(target)
        end

        # Pre-populate information in chef
        section("Syncing to chef")
        target.save :providers => :chef

        unless target.empty?
          ui.info "Preparing shared resources:"
          all_computers(*@name_args).prepare
        end

        # Launch computers
        ui.info("")
        section("Launching computers", :green)
        display(target)
        launched = target.launch

        # As each server finishes, configure it. If we received an
        # exception launching any of the machines, remember it.

        launch_succeeded = true
        Ironfan.parallel(launched) do |computer|
          if (computer.is_a?(Exception)) then
            ui.error "Error launching #{computer.inspect}; skipping after-launch tasks.";
            launch_succeeded = false
          else
            perform_after_launch_tasks(computer) if computer.machine.perform_after_launch_tasks?
          end
        end

        if healthy? and launch_succeeded
          section('All computers launched correctly', :white)
          section('Applying aggregations:')
          all_computers(*@name_args).aggregate
        else
          section('Some computers could not be launched')
          exit 1
        end

        display(target)
      end

      def perform_after_launch_tasks(computer)
        # Try SSH
        unless config[:dry_run]
          if config[:wait_ssh]
            Ironfan.step(computer.name, 'trying ssh', :white)
            nil until wait_for_ssh(computer){ sleep @initial_sleep_delay ||= 10  }
          end
        end
        
        # Run Bootstrap
        if config[:bootstrap]
          Ironfan.step(computer.name, 'bootstrapping', :green)
          run_bootstrap(computer)
        end
      end

      def warn_or_die_on_bogus_servers(target)
        ui.info("")
        ui.info "Cluster has servers in a transitional or undefined state (shown as 'bogus'):"
        ui.info("")
        display(target)
        ui.info("")
        unless config[:force]
          die(
            "Launch operations may be unpredictable under these circumstances.",
            "You should wait for the cluster to stabilize, fix the undefined server problems",
            "(run \"knife cluster show CLUSTER\" to see what the problems are), or launch",
            "the cluster anyway using the --force option.", "", -2)
        end
        ui.info("")
        ui.info "--force specified"
        ui.info "Proceeding to launch anyway. This may produce undesired results."
        ui.info("")
      end

    end
  end
end
