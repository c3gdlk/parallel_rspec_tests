require 'open3'
require 'fileutils'

namespace :smoke do
  task :create do
    processes = fetch_processes_count

    threads = []
    processes.times do |i|
      threads << run_comman_in_thread("cd #{Rails.root.to_s} && bundle exec rake db:create RAILS_ENV=test TEST_ENV_NUMBER=#{i}")
    end

    threads.each(&:join)
    puts 'Done'
  end

  task :drop do
    processes = fetch_processes_count

    threads = []
    processes.times do |i|
      threads << run_comman_in_thread(env_issue_cmd i, "bundle exec rake db:drop")
    end

    threads.each(&:join)
    puts 'Done'
  end

  task :prepare do
    processes = fetch_processes_count

    threads = []
    processes.times do |i|
      threads << run_comman_in_thread(env_issue_cmd i, "bundle exec rake db:schema:load")
    end

    threads.each(&:join)
    puts 'Done'
  end

  task :calibrate do
    data = {}
    suite_load_time = ENV['SUITE_LOAD_TIME'] || 5

    Dir[File.join('spec', '**{,/*/**}/*_spec.rb')].uniq.each do |file_name|
      t_start = Time.now.to_i
      system("cd #{Rails.root.to_s} && bundle exec rspec #{file_name}")
      t_end = Time.now.to_i

      data[file_name] = t_end - t_start - suite_load_time
      putc '.'
    end

    File.open(Rails.root.join('smoke.calibration.json').to_s, 'w') do |f|
      f.puts data.to_json
    end
  end

  task :run do
    start_time = Time.now.to_i
    processes = fetch_processes_count

    # generate tmp folder
    work_dir = Rails.root.join('tmp/smoke')
    work_dir.rmtree rescue Errno::ENOENT
    work_dir.mkpath

    work_dir_path = work_dir.to_s

    # Group spec examples by buckets
    if File.file?(Rails.root.join('smoke.calibration.json').to_s)
      buckets = load_buckets_by_time(processes)
    else
      buckets = []

      Dir[File.join('spec', '**{,/*/**}/*_spec.rb')].uniq.each_with_index do |file_name, i|
        buckets[i % processes] ||= []
        buckets[i % processes] << file_name
      end
    end

    # Create dirs for each group
    spec_group_folders = []
    processes.times do |i|
      dir = Rails.root.join("tmp/smoke/group#{i}")
      dir.mkpath

      spec_group_folders << dir.to_s
    end

    #Generate overmind workers
    overmind_workers = []
    processes.times do |i|
      overmind_workers << "rspec#{i}"
    end

    # Generate sh files
    # Need because of Overmind limit
    processes.times do |i|
      filename = Rails.root.join("rspec_runner_#{i}.sh").to_s
      File.open(filename, 'w') do |f|
        f.puts "TEST_ENV_NUMBER=#{i} bundle exec rspec -o #{spec_group_folders[i]}/rspec.log #{buckets[i].join(' ')} && touch #{spec_group_folders[i]}/rspec.success || touch #{spec_group_folders[i]}/rspec.failure"
      end
      File.chmod(0777, filename)
    end

    # Generate overmind Procfile
    File.open(Rails.root.join("Procfile.smoke").to_s, 'w') do |f|
      processes.times do |i|
        f.puts "#{overmind_workers[i]}: ./rspec_runner_#{i}.sh"
      end
    end

    file_generation_time = Time.now.to_i - start_time

    overmind_socket_file = Rails.root.join("tmp/smoke/overmind.sock").to_s

    overmind = Thread.new do
      system "cd #{Rails.root.to_s} && overmind start -s #{overmind_socket_file} -c #{overmind_workers.join(',')} -f Procfile.smoke"
    end

    success_file = -> (folder) { Rails.root.join(folder, 'rspec.success').to_s }
    failure_file = -> (folder) { Rails.root.join(folder, 'rspec.failure').to_s }

    monitor = Thread.new do
      loop do
        is_done = spec_group_folders.all? do |folder|
          File.file?(failure_file.call(folder)) || File.file?(success_file.call(folder))
        end

        break if is_done
        sleep 5
      end

      system "overmind kill -s #{overmind_socket_file}"
      Thread.kill overmind
    end

    monitor.join
    success = spec_group_folders.all? { |folder| File.file?(success_file.call(folder)) }
    success_label = success ? 'Success' : 'Failure'

    processes.times do |i|
      system "cat #{spec_group_folders[i]}/rspec.log"
    end

    end_time = Time.now.to_i
    puts "Took #{file_generation_time} to generate configs"
    puts "#{success_label}. Done in: #{end_time - start_time} seconds"

    puts "Cleaning up"
    processes.times do |i|
      FileUtils.rm(Rails.root.join("rspec_runner_#{i}.sh").to_s)
    end
    FileUtils.rm(Rails.root.join("Procfile.smoke").to_s)
    work_dir.rmtree
  end

  def fetch_processes_count
    (ENV['PROCESSES_COUNT'] || 4).to_i
  end

  def env_issue_cmd(i, cmd)
    "cd #{Rails.root.to_s} && bin/rails db:environment:set RAILS_ENV=test TEST_ENV_NUMBER=#{i} && #{cmd} RAILS_ENV=test TEST_ENV_NUMBER=#{i}"
  end

  def run_comman_in_thread(cmd)
    Thread.new do
      out, err, process = Open3.capture3(cmd)
      unless process.success?
        puts 'Fail to execute: ' + cmd
        puts err if ENV['SMOKE_DEBUG'].present?
      end
    end
  end

  def load_buckets_by_time(processes)
    data = JSON.parse(Rails.root.join('smoke.calibration.json').read)

    avg = -> (file_name) do
      folder = file_name.split('/')[1]

      other_specs = data.select { |k,v| k.start_with?("spec/#{folder}") }

      if other_specs.present?
        other_specs.values.sum / other_specs.values.size
      else
        data.values.sum / data.values.size
      end
    end

    buckets = []
    buckets_sizes = []

    processes.times do |i|
      buckets[i] = []
      buckets_sizes[i] = 0
    end

    Dir[File.join('spec', '**{,/*/**}/*_spec.rb')].uniq.each do |file_name|
      i = buckets_sizes.index(buckets_sizes.min)

      buckets[i] << file_name
      buckets_sizes[i] += data[file_name] || avg.(file_name)
    end

    puts "After calibration expected time is about #{buckets_sizes.max} seconds"

    buckets
  end
end
