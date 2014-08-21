require 'oops/opsworks_deploy'
require 'aws-sdk'
require 'rake'

module Oops
  class Tasks
    attr_accessor :prerequisites, :additional_paths, :includes, :excludes, :format

    def self.default_args
      {
        prerequisites: ['oops:compile'],
        additional_paths: [],
        includes: ['public/assets', 'public/packs'],
        excludes: ['.gitignore'],
        format: 'zip'
      }
    end

    def initialize(&block)
      self.class.default_args.each do |key, value|
        public_send("#{key}=", value)
      end
      yield(self)
      create_task!
    end

    def add_file file_path, path
      if format == 'zip'
        sh *%W{zip -r -g build/#{file_path} #{path}}
      elsif format == 'tar'
        sh *%W{tar -r -f build/#{file_path} #{path}}
      end
    end

    def remove_file file_path, path
      if format == 'zip'
        sh *%W{zip build/#{file_path} -d #{path}}
      elsif format == 'tar'
        sh *%W{tar --delete -f build/#{file_path} #{path}}
      end
    end

    private
    include Rake::DSL
    def create_task!
      # Remove any existing definition
      Rake::Task["oops:build"].clear if Rake::Task.task_defined?("oops:build")

      namespace :oops do
        task :build, [:filename] => prerequisites do |t, args|
          args.with_defaults filename: default_filename

          file_path = args.filename

          sh %{mkdir -p build}
          sh %{git archive --format #{format} --output build/#{file_path} HEAD}

          (includes + additional_paths).each do |path|
            add_file file_path, path
          end

          excludes.each do |path|
            remove_file file_path, path
          end

          puts "Packaged Application: #{file_path}"
        end
      end
    end
  end
end

# Initialize build task with defaults
Oops::Tasks.new do
end

namespace :oops do

  task :compile do
    puts "starting asset compilation"
    `RAILS_ENV=production bundle exec rake assets:clean assets:precompile`
    abort "asset compitation error" if $? != 0
  end

  task :setup_aws do
    config_file = File.expand_path("~/.aws/config")
    if File.exist?(config_file)
      puts "loading credentials from #{config_file}"
      config = ParseConfig.new(config_file)
      AWS.config(
        region: config['default']['region'],
        access_key_id: config['default']['aws_access_key_id'],
        secret_access_key: config['default']['aws_secret_access_key'])
    end
  end

  desc "upload built archive"
  task :upload, [:filename] => :setup_aws do |t, args|
    args.with_defaults filename: default_filename

    file_path = args.filename
    s3 = s3_object(file_path)

    puts "Starting upload..."
    s3.upload_file("build/#{file_path}")
    puts "Uploaded Application: #{s3.public_url}"
  end

  desc "deploy uploaded archive"
  task :deploy, [:app_name, :stack_name, :filename] => :setup_aws do |t, args|
    abort "app_name variable is required" unless (app_name = args.app_name)
    abort "stack_name variable is required" unless (stack_name = args.stack_name)
    make_sure_git_is_up_to_date
    args.with_defaults filename: default_filename
    file_path = args.filename
    file_url = s3_url file_path

    ENV['AWS_REGION'] ||= 'us-east-1'

    if !s3_object(file_path).exists?
      abort "Artifact \"#{file_url}\" doesn't seem to exist\nMake sure you've run `RAILS_ENV=deploy rake opsworks:build opsworks:upload` before deploying"
    end

    Rake::Task['oops:deploy_start'].invoke

    ops = Oops::OpsworksDeploy.new args.app_name, args.stack_name
    deployment = ops.deploy(file_url)

    STDOUT.sync = true
    STDOUT.print "Deploying #{build_hash[0..7]} "
    loop do
      STDOUT.print "."
      break if deployment.finished?
      sleep 5
    end

    STDOUT.puts "\nStatus: #{deployment.status}"
    if deployment.failed?
      Rake::Task['oops:deploy_failed'].invoke
      abort "Deploy failed. Check the OpsWorks console."
    else
      Rake::Task['oops:deploy_finished'].invoke
    end
  end

  task :deploy_start do
    # hook
  end
  task :deploy_failed do
    # hook
  end
  task :deploy_finished do
    # hook
  end

  private
  def s3_object file_path
    s3 = Aws::S3::Resource.new
    s3.bucket(bucket_name).object("#{package_folder}/#{file_path}")
  end

  def s3_url file_path
    s3_object(file_path).public_url.to_s
  end

  def make_sure_git_is_up_to_date
    gitout = `git fetch origin --dry-run 2>&1`
    unless gitout.blank?
      abort "git repositry not up to date, git pull first!"
    else
      puts "git ok"
    end
  end

  def build_hash
    @build_hash ||= `git rev-parse HEAD`.strip
  end

  def default_filename
    ENV['PACKAGE_FILENAME'] || "git-#{build_hash}.zip"
  end

  def package_folder
    abort "PACKAGE_FOLDER environment variable required" unless ENV['PACKAGE_FOLDER']
    ENV['PACKAGE_FOLDER']
  end

  def bucket_name
    abort "DEPLOY_BUCKET environment variable required" unless ENV['DEPLOY_BUCKET']
    ENV['DEPLOY_BUCKET']
  end

end
