# test_suite.rb
require 'minitest/autorun'
require 'open3'
require 'securerandom'

require_relative 'rails'

# ==============================================================================
# 1. UNIT TESTS: Launcher (CLI Argument Parsing & System Logic)
# ==============================================================================
class RailsLauncherTest < Minitest::Test
  def setup
    @log_file = "test.log"
    File.write(@log_file, "dummy content")
    @default_args = ["--log-file", @log_file] 
  end

  def teardown
    File.delete(@log_file) if File.exist?(@log_file)
  end

  def test_defaults
    launcher = RailsLog::Launcher.new(@default_args).build!
    assert_equal 500, launcher.options[:slow_ms]
    assert_equal @log_file, launcher.options[:log_file]
    assert_includes launcher.options[:flags], "sql"
  end

  def test_manual_flag_overrides
    args = @default_args + ["--slow-ms=1000", "--time"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_equal 1000, launcher.options[:slow_ms]
    assert_equal true, launcher.options[:show_time]
    assert_equal '1000', launcher.env_vars['S_SLOW_MS']
  end

  def test_exclude_concatenation
    args = @default_args + ["--exclude-path=/api", "--exclude-path=/cable"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_equal "/api|/cable", launcher.options[:exclude]['path']
  end

  def test_specific_hide_flags
    args = @default_args + ["--hide-rb=internal", "--hide-sql=Session"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_equal "internal", launcher.options[:hide]['rb']
    assert_equal "Session", launcher.options[:hide]['sql']
  end

  def test_exclude_controller_action_option
    args = @default_args + ["--exclude-controller-action=UsersController#show"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_equal "UsersController#show", launcher.options[:exclude]['controller_action']
  end

  def test_exclude_controller_action_concatenation
    args = @default_args + ["-exca=UsersController#show", "-exca=PostsController#index"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_equal "UsersController#show|PostsController#index", launcher.options[:exclude]['controller_action']
  end

  def test_grep_command_generation
    args = @default_args + ["--include-flag=sql,error"]
    launcher = RailsLog::Launcher.new(args).build!
    cmd = launcher.command_string
    assert_includes cmd, "grep -a"
    assert_includes cmd, "tail -f #{@log_file}"
    assert_includes cmd, "Update All" 
  end

  def test_launcher_missing_file_abort
    launcher = RailsLog::Launcher.new(["--log-file", "nonexistent.log"])
    mocked_death = false
    launcher.define_singleton_method(:die!) { |msg| mocked_death = true }
    launcher.build!
    assert mocked_death, "Launcher should have called die! for missing file"
  end

  def test_full_launch_execution_flow
    launcher = RailsLog::Launcher.new(@default_args)
    executed = false
    launcher.define_singleton_method(:launch!) { |env, cmd| executed = true }
    launcher.build!
    launcher.launch!(launcher.env_vars, launcher.command_string)
    assert executed
  end
end

# ==============================================================================
# 2. INTEGRATION TESTS: Processor (Log Formatting & Parsing)
# ==============================================================================
class RailsProcessorTest < Minitest::Test
  SCRIPT_PATH = "./rails.rb"

  COMPLEX_LOG = <<~LOG
    [92442d07-e372-4575-928f-3b1f56049953] Started GET "/acc_m6r35t56/events" for ::1 at 2025-12-01 20:41:10 +0700
    [92442d07-e372-4575-928f-3b1f56049953] Processing by GatheringsController#index as HTML
    [92442d07-e372-4575-928f-3b1f56049953] Parameters: {"account_id" => "acc_m6r35t56"}
    [92442d07-e372-4575-928f-3b1f56049953]    Session Load (0.6ms)  SELECT "sessions".* FROM "sessions" WHERE "sessions"."token" = 'gxwSV68NGEYnvf4paZqxZKkH' LIMIT 1
    [92442d07-e372-4575-928f-3b1f56049953] Completed 200 OK in 209ms (Views: 91.0ms | ActiveRecord: 11.9ms (25 queries, 0 cached) | GC: 0.0ms)

    [4ef4732e-3d01-4658-9f3a-002e5aa4452e] Started GET "/users/usr_AmQiG/avatar?account_id=acc_m6r35t56&v=20251201200214" for ::1 at 2025-12-01 20:41:10 +0700
    [4ef4732e-3d01-4658-9f3a-002e5aa4452e] Processing by Users::AvatarsController#show as HTML
    [4ef4732e-3d01-4658-9f3a-002e5aa4452e] Completed 304 Not Modified in 185ms (ActiveRecord: 7.0ms (1 query, 0 cached) | GC: 3.6ms)

    [2862ad08-df24-4246-bb3d-e5b393bc5a75] Started GET "/default_image?account_id=acc_m6r35t56&size=email_banner" for ::1 at 2025-12-01 20:41:12 +0700
    [2862ad08-df24-4246-bb3d-e5b393bc5a75] Processing by DefaultImageController#show as HTML
    [2862ad08-df24-4246-bb3d-e5b393bc5a75]    Parameters: {"account_id" => "acc_m6r35t56", "size" => "email_banner"}
    [2862ad08-df24-4246-bb3d-e5b393bc5a75] Redirected to http://localhost:3001/assets/default-banner-new-c28fe4c0.png
    [2862ad08-df24-4246-bb3d-e5b393bc5a75] Completed 302 Found in 40ms (ActiveRecord: 0.0ms (0 queries, 0 cached) | GC: 0.4ms)

    [bda436d9-9e83-41b5-87bd-5742844e91ba] Started POST "/acc_m6r35t56/events" for ::1 at 2025-12-01 20:41:14 +0700
    [bda436d9-9e83-41b5-87bd-5742844e91ba] Processing by GatheringsController#create as TURBO_STREAM
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Parameters: {"authenticity_token" => "[FILTERED]", "gathering" => {"name" => "asdf"}}
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Session Load (0.4ms)  SELECT "sessions".* FROM "sessions" WHERE "sessions"."token" = 'gxwSV68NGEYnvf4paZqxZKkH' LIMIT 1
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    TRANSACTION (0.1ms)  BEGIN
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Gathering Create (0.9ms)  INSERT INTO "gatherings" ("account_id", "name") VALUES (18, 'asdf') RETURNING "id"
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Question Update All (4.4ms)  UPDATE "questions" SET "position_in_parent" = "position_in_parent" * -1
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Questions::FirstName Create (0.2ms)  INSERT INTO "questions" ("label", "type") VALUES ('First Name', 'Questions::FirstName')
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    Templates::AutoEmails::CheckInEmail Create (1.1ms)  INSERT INTO "templates" ("title") VALUES ('On-site Check-in')
    [bda436d9-9e83-41b5-87bd-5742844e91ba]    TRANSACTION (0.6ms)  COMMIT
    [bda436d9-9e83-41b5-87bd-5742844e91ba] Redirected to http://localhost:3001/acc_m6r35t56/events/evt_epytrW
    [bda436d9-9e83-41b5-87bd-5742844e91ba] Completed 302 Found in 1373ms (ActiveRecord: 163.6ms (175 queries, 0 cached) | GC: 43.6ms)

    [2b2b05c7-90c5-4a72-802c-7f22819675db] Started DELETE "/acc_m6r35t56/events/evt_epytrW/locations/5" for ::1 at 2025-12-01 20:41:27 +0700
    [2b2b05c7-90c5-4a72-802c-7f22819675db] Processing by LocationsController#destroy as TURBO_STREAM
    [2b2b05c7-90c5-4a72-802c-7f22819675db]    Location Destroy (1.5ms)  DELETE FROM "locations" WHERE "locations"."id" = 5
    [2b2b05c7-90c5-4a72-802c-7f22819675db] Completed 302 Found in 76ms (ActiveRecord: 6.6ms (10 queries, 0 cached) | GC: 0.0ms)

    [aa39e3a3-c95d-4360-b411-c2f062cdb060] Started GET "/acc_m6r35t56/events/evt_epytrW/locations" for ::1 at 2025-12-01 20:41:23 +0700
    [aa39e3a3-c95d-4360-b411-c2f062cdb060] Processing by LocationsController#index as TURBO_STREAM
    [aa39e3a3-c95d-4360-b411-c2f062cdb060]    Rendered locations/_list.html.erb (Duration: 19.5ms | GC: 0.0ms)
    [aa39e3a3-c95d-4360-b411-c2f062cdb060]    Rendered locations/index.html.erb (Duration: 5.0ms)
    [aa39e3a3-c95d-4360-b411-c2f062cdb060] Completed 200 OK in 174ms
  LOG

  def run_parser(input_data, env_vars = {})
    defaults = {
      'S_PATH'=>'1', 'S_CONTROLLER'=>'1', 'S_ACTION'=>'1', 
      'S_PARAMS'=>'1', 'S_SQL'=>'1', 'S_HTML'=>'1', 'S_RB'=>'1', 'S_LOG'=>'1', 'S_STATUS'=>'1'
    }
    stdout, stderr, status = Open3.capture3(defaults.merge(env_vars), "ruby #{SCRIPT_PATH} -i", stdin_data: input_data)
    unless status.success?
      puts stderr; raise "Parser crashed"
    end
    stdout.gsub(/\e\[([;\d]+)?m/, '')
  end

  def test_heavy_create_action_with_transactions
    env = { 'S_EX_CONTROLLER' => 'Locations|Users|DefaultImage' }
    output = run_parser(COMPLEX_LOG, env)

    assert_match /c: GatheringsController/, output
    assert_match /a: create/, output
    assert_match /p:/, output
    assert_match /name: asdf/, output
    assert_match /Gathering Create/, output
    # SQL is shortened - only shows model and duration, not full query
    assert_match /TRANSACTION .* BEGIN/, output
    assert_match /TRANSACTION .* COMMIT/, output
    assert_match /1373ms/, output
  end

  def test_asset_304_not_modified
    output = run_parser(COMPLEX_LOG)
    assert_match /c: Users::AvatarsController/, output
    assert_match /a: show/, output
    assert_match /s: 304/, output
  end

  def test_redirect_302
    output = run_parser(COMPLEX_LOG)
    assert_match /c: DefaultImageController/, output
    assert_match /a: show/, output
    assert_match /s: 302/, output
  end

  def test_delete_action_sql
    output = run_parser(COMPLEX_LOG)
    assert_match /c: LocationsController/, output
    assert_match /a: destroy/, output
    assert_match /Location Destroy/, output
    # SQL is shortened - only shows model and duration, not full query
  end

  def test_turbo_stream_rendering
    output = run_parser(COMPLEX_LOG)
    assert_match /c: LocationsController/, output
    assert_match /_list.html.erb/, output
  end

  def test_file_grouping_logic
    output = run_parser(COMPLEX_LOG)
    assert_equal 1, output.scan(/^\s+locations\/$/).size
    assert_match /_list\.html\.erb/, output
    assert_match /index\.html\.erb/, output
  end

  def test_hide_rb_stack_trace
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index
      [#{uuid}] app/services/bad_service.rb:50:in `call'
      [#{uuid}] app/models/user.rb:10:in `valid?'
      [#{uuid}] Completed 500 Internal Server Error in 10ms
    LOG

    output = run_parser(log)
    assert_match /bad_service\.rb/, output

    env = { 'S_HIDE_RB' => 'bad_service' }
    output_hidden = run_parser(log, env)
    
    refute_match /bad_service\.rb/, output_hidden
    assert_match /user\.rb/, output_hidden 
  end

  def test_hide_html_rendering
    env = { 'S_HIDE_HTML' => '_list' }
    output = run_parser(COMPLEX_LOG, env)
    assert_match /index\.html\.erb/, output
    refute_match /_list\.html\.erb/, output
  end

  def test_hide_standard_log
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by C#a
      [#{uuid}]    ==> This is a debug message
      [#{uuid}]    ==> This is a secret message
      [#{uuid}] Completed 200 OK in 10ms
    LOG

    env = { 'S_LOG' => '1', 'S_HIDE_LOG' => 'secret' }
    output = run_parser(log, env)

    assert_match /debug message/, output
    refute_match /secret message/, output
  end

  def test_sql_classification_fallback
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by C#a
      [#{uuid}]    User Load (0.1ms) SELECT * FROM users
      [#{uuid}]    User Update (0.0ms) UPDATE users SET x=1
      [#{uuid}] Completed 200 OK in 10ms
    LOG

    env = { 'S_SQL_UPDATE' => '1', 'S_SQL_READ' => nil }
    output = run_parser(log, env)

    # SQL is shortened - only shows model and duration
    assert_match /User Update/, output
    refute_match /User Load/, output
  end

  def test_buffer_rotation
    # Covers @req_buffer.shift logic
    processor = RailsLog::Processor.new
    buffer = processor.instance_variable_get(:@req_buffer)
    
    60.times do |i|
      # Valid Hex UUID required for parser
      uuid = "a0a0a0a0-0000-0000-0000-#{i.to_s.rjust(12, '0')}"
      processor.send(:process_line, "[#{uuid}] Started GET /")
    end

    # The code uses `> 50`, so the buffer sits at 51 (50 old + 1 new)
    assert_equal 51, buffer.size 
    assert buffer.key?("a0a0a0a0-0000-0000-0000-000000000059")
    refute buffer.key?("a0a0a0a0-0000-0000-0000-000000000000")
  end

  def test_error_cleanup_on_next_request
    # Covers line 257: Flushing a previous "failed/kept" request when a new one starts
    uuid1 = "a0a0a0a0-0000-0000-0000-000000000001"
    uuid2 = "a0a0a0a0-0000-0000-0000-000000000002"
    
    log = <<~LOG
      [#{uuid1}] Started GET "/error"
      [#{uuid1}] Completed 500 Internal Server Error in 10ms
      [#{uuid2}] Started GET "/next"
      [#{uuid2}] Completed 200 OK in 10ms
    LOG

    output = run_parser(log)
    
    # Both should appear, proving the buffer didn't get stuck on the error
    assert_match /s: 500/, output
    assert_match /s: 200/, output
  end

  def test_invalid_regex_handling
    # FIX: Added quotes around path "/" so regex matches properly
    log = "[abc] Started GET \"/\"\n[abc] Completed 200 OK in 10ms"
    env = { 'S_EX_GLOBAL' => '(' } # Invalid regex
    output = run_parser(log, env)
    assert_match /s: 200/, output # Should not crash
  end

  def test_exclude_controller_action_combined
    # Test that controller+action exclusion only excludes when BOTH match
    uuid1 = SecureRandom.hex
    uuid2 = SecureRandom.hex
    uuid3 = SecureRandom.hex
    log = <<~LOG
      [#{uuid1}] Started GET "/users/1"
      [#{uuid1}] Processing by UsersController#show as HTML
      [#{uuid1}] Completed 200 OK in 10ms

      [#{uuid2}] Started GET "/users"
      [#{uuid2}] Processing by UsersController#index as HTML
      [#{uuid2}] Completed 200 OK in 10ms

      [#{uuid3}] Started GET "/posts/1"
      [#{uuid3}] Processing by PostsController#show as HTML
      [#{uuid3}] Completed 200 OK in 10ms
    LOG

    # Exclude only UsersController#show, not UsersController#index or PostsController#show
    env = { 'S_EX_CONTROLLER_ACTION' => 'UsersController#show' }
    output = run_parser(log, env)

    # UsersController#show should be excluded
    refute_match /c: UsersController\n\s+a: show/, output

    # UsersController#index should NOT be excluded
    assert_match /c: UsersController/, output
    assert_match /a: index/, output

    # PostsController#show should NOT be excluded
    assert_match /c: PostsController/, output
    assert_match /a: show/, output
  end

  def test_exclude_controller_action_multiple
    uuid1 = SecureRandom.hex
    uuid2 = SecureRandom.hex
    uuid3 = SecureRandom.hex
    log = <<~LOG
      [#{uuid1}] Started GET "/users/1"
      [#{uuid1}] Processing by UsersController#show as HTML
      [#{uuid1}] Completed 200 OK in 10ms

      [#{uuid2}] Started GET "/posts"
      [#{uuid2}] Processing by PostsController#index as HTML
      [#{uuid2}] Completed 200 OK in 10ms

      [#{uuid3}] Started GET "/comments"
      [#{uuid3}] Processing by CommentsController#index as HTML
      [#{uuid3}] Completed 200 OK in 10ms
    LOG

    # Exclude both UsersController#show and PostsController#index
    env = { 'S_EX_CONTROLLER_ACTION' => 'UsersController#show|PostsController#index' }
    output = run_parser(log, env)

    # Both should be excluded
    refute_match /c: UsersController/, output
    refute_match /c: PostsController/, output

    # CommentsController should NOT be excluded
    assert_match /c: CommentsController/, output
    assert_match /a: index/, output
  end

  def test_exclude_controller_action_regex
    uuid1 = SecureRandom.hex
    uuid2 = SecureRandom.hex
    log = <<~LOG
      [#{uuid1}] Started GET "/users/1/avatar"
      [#{uuid1}] Processing by Users::AvatarsController#show as HTML
      [#{uuid1}] Completed 200 OK in 10ms

      [#{uuid2}] Started GET "/users/1"
      [#{uuid2}] Processing by UsersController#show as HTML
      [#{uuid2}] Completed 200 OK in 10ms
    LOG

    # Use regex to exclude any controller ending with Controller#show
    env = { 'S_EX_CONTROLLER_ACTION' => 'AvatarsController#show' }
    output = run_parser(log, env)

    # AvatarsController#show should be excluded
    refute_match /AvatarsController/, output

    # UsersController#show should NOT be excluded
    assert_match /c: UsersController/, output
  end

  def test_mid_stream_tailing
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Processing by OrphanController#index
      [#{uuid}] Completed 200 OK in 50ms
    LOG
    
    output = run_parser(log)
    refute_match /Started/, output
  end

  def test_main_cli_entry_point
    stdout, _, _ = Open3.capture3("ruby #{SCRIPT_PATH} -i", stdin_data: "")
    assert_equal "", stdout
  end
end

# ==============================================================================
# 3. COVERAGE GAPS (Edge Cases & Missing Branches)
# ==============================================================================
class RailsCoverageGapTest < Minitest::Test
  SCRIPT_PATH = "./rails.rb"

  def run_parser(input)
    # Inject default flags so the Processor knows what to print
    defaults = {
      'S_PATH'=>'1', 'S_CONTROLLER'=>'1', 'S_ACTION'=>'1', 
      'S_PARAMS'=>'1', 'S_SQL'=>'1', 'S_HTML'=>'1', 'S_RB'=>'1', 'S_LOG'=>'1', 'S_STATUS'=>'1'
    }
    stdout, _, _ = Open3.capture3(defaults, "ruby #{SCRIPT_PATH} -i", stdin_data: input)
    stdout
  end

  def test_cable_requests_shown
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/cable"
      [#{uuid}] Processing by ActionCable::Server::Base#index as HTML
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /cable/, output
  end

  def test_em_dash_handling
    launcher = RailsLog::Launcher.new(["—slow-ms=999", "–time", "--log-file", "fixtures/complex.log"]) # Em-dash and En-dash
    launcher.build!
    assert_equal 999, launcher.options[:slow_ms]
    assert_equal true, launcher.options[:show_time]
  end

  def test_complex_html_regex
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by A#b
      [#{uuid}]    Rendered layout layouts/app.html.erb (Duration: 1ms)
      [#{uuid}]    Rendered collection of posts/_post.html.erb (Duration: 1ms)
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /layouts\/app\.html\.erb/, output
    assert_match /posts\/_post\.html\.erb/, output
  end

  def test_stack_trace_suppression
    uuid = SecureRandom.hex
    # Stack trace must appear AFTER 'Completed' to test the buffer flush suppression
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by A#b
      [#{uuid}] Completed 500 Error in 10ms
      [#{uuid}] app/first.rb:1:in `a'
      [#{uuid}] app/second.rb:2:in `b'
    LOG
    output = run_parser(log)
    
    assert_match /first\.rb/, output
    refute_match /second\.rb/, output 
  end

  def test_cli_banner_output
    out, _ = capture_io do
      launcher = RailsLog::Launcher.new(["--log-file", "fixtures/complex.log"])
      launcher.define_singleton_method(:launch!) { |_,_| }

      RailsLog::Launcher.stub :new, launcher do
        RailsLog.start([])
      end
    end
    assert_match /Rails Log Launcher/, out
  end
end

# ==============================================================================
# 4. ADDITIONAL COVERAGE TESTS
# ==============================================================================
class RailsAdditionalCoverageTest < Minitest::Test
  SCRIPT_PATH = "./rails.rb"

  def run_parser(input, env_vars = {})
    defaults = {
      'S_PATH'=>'1', 'S_CONTROLLER'=>'1', 'S_ACTION'=>'1',
      'S_PARAMS'=>'1', 'S_SQL'=>'1', 'S_HTML'=>'1', 'S_RB'=>'1', 'S_LOG'=>'1', 'S_STATUS'=>'1', 'S_ERROR'=>'1'
    }
    stdout, _, _ = Open3.capture3(defaults.merge(env_vars), "ruby #{SCRIPT_PATH} -i", stdin_data: input)
    stdout.gsub(/\e\[([;\d]+)?m/, '')
  end

  # Test signal handlers setup
  def test_signal_handlers_setup
    processor = RailsLog::Processor.new
    # Just verify it doesn't crash - signal handlers are set in initialize
    assert processor
  end

  # Test params with arrays
  def test_params_with_arrays
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started POST "/users"
      [#{uuid}] Processing by UsersController#create as HTML
      [#{uuid}] Parameters: {"user" => {"name" => "John", "tags" => ["admin", "user"]}}
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /tags:/, output
    assert_match /admin/, output
  end

  # Test params eval fallback with malformed params
  def test_params_eval_fallback
    uuid = SecureRandom.hex
    # Use valid hash syntax that will fail eval (unquoted string)
    log = <<~LOG
      [#{uuid}] Started POST "/users"
      [#{uuid}] Processing by UsersController#create as HTML
      [#{uuid}] Parameters: {"key" => Object.new}
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    # Should not crash, fallback prints raw params
    assert_match /p:/, output
  end

  # Test single file in root directory (no grouping)
  def test_single_file_no_grouping
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index as HTML
      [#{uuid}]    Rendered home.html.erb (Duration: 1ms)
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /home\.html\.erb/, output
  end

  # Test hidden rb in post-flush stack trace
  def test_hidden_rb_post_flush
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by A#b
      [#{uuid}] Completed 500 Error in 10ms
      [#{uuid}] app/services/secret_service.rb:1:in `call'
    LOG
    env = { 'S_HIDE_RB' => 'secret' }
    output = run_parser(log, env)
    refute_match /secret_service/, output
  end

  # Test SQL Destroy classification
  def test_sql_destroy_classification
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started DELETE "/posts/1"
      [#{uuid}] Processing by PostsController#destroy as HTML
      [#{uuid}]    Post Destroy (0.5ms) DELETE FROM posts WHERE id = 1
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SQL_DELETE' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /Post Destroy/, output
  end

  # Test SQL Exists classification
  def test_sql_exists_classification
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/posts/1"
      [#{uuid}] Processing by PostsController#show as HTML
      [#{uuid}]    Post Exists? (0.3ms) SELECT 1 FROM posts WHERE id = 1 LIMIT 1
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SQL_READ' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /Post Exists\?/, output
  end

  # Test SQL Count classification
  def test_sql_count_classification
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/posts"
      [#{uuid}] Processing by PostsController#index as HTML
      [#{uuid}]    Post Count (0.2ms) SELECT COUNT(*) FROM posts
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SQL_READ' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /Post Count/, output
  end

  # Test simple_sql flag
  def test_simple_sql_flag
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/posts"
      [#{uuid}] Processing by PostsController#index as HTML
      [#{uuid}]    Post Load (0.5ms) SELECT * FROM posts
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SIMPLE_SQL' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /Post Load/, output
  end

  # Test exclude-error option
  def test_exclude_error
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index as HTML
      [#{uuid}]    NoMethodError: undefined method 'foo'
      [#{uuid}] Completed 500 Error in 10ms
    LOG
    env = { 'S_EX_ERROR' => 'NoMethodError' }
    output = run_parser(log, env)
    refute_match /HomeController/, output
  end

  # Test exclude-log option
  def test_exclude_log
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index as HTML
      [#{uuid}]    ==> secret debug info
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_EX_LOG' => 'secret' }
    output = run_parser(log, env)
    refute_match /HomeController/, output
  end

  # Test include-flag with simple_sql in launcher
  def test_launcher_simple_sql_flag
    log_file = "test_simple_sql.log"
    File.write(log_file, "dummy")
    args = ["--log-file", log_file, "--include-flag=simple_sql"]
    launcher = RailsLog::Launcher.new(args).build!
    assert_includes launcher.options[:flags], "simple_sql"
    assert_includes launcher.command_string, "Load"
    File.delete(log_file)
  end

  # Test SQL Insert fallback classification
  def test_sql_insert_fallback
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started POST "/posts"
      [#{uuid}] Processing by PostsController#create as HTML
      [#{uuid}]    SQL (0.5ms) INSERT INTO posts (title) VALUES ('test')
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SQL_CREATE' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /SQL \(0\.5ms\)/, output
  end

  # Test SQL Delete fallback classification
  def test_sql_delete_fallback
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started DELETE "/posts/1"
      [#{uuid}] Processing by PostsController#destroy as HTML
      [#{uuid}]    SQL (0.5ms) DELETE FROM posts WHERE id = 1
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    env = { 'S_SQL_DELETE' => '1', 'S_SQL' => nil }
    output = run_parser(log, env)
    assert_match /SQL \(0\.5ms\)/, output
  end

  # Test error line in post-flush
  def test_error_in_post_flush
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by A#b
      [#{uuid}] Completed 500 Error in 10ms
      [#{uuid}] RuntimeError: something went wrong
    LOG
    output = run_parser(log)
    assert_match /RuntimeError/, output
  end

  # Test jobs directory in rb paths
  def test_jobs_directory_cleanup
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index as HTML
      [#{uuid}] app/jobs/cleanup_job.rb:10:in `perform'
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /cleanup_job\.rb/, output
    refute_match /app\/jobs\//, output
  end

  # Test mailers directory in rb paths
  def test_mailers_directory_cleanup
    uuid = SecureRandom.hex
    log = <<~LOG
      [#{uuid}] Started GET "/"
      [#{uuid}] Processing by HomeController#index as HTML
      [#{uuid}] app/mailers/user_mailer.rb:5:in `welcome'
      [#{uuid}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    assert_match /user_mailer\.rb/, output
    refute_match /app\/mailers\//, output
  end

  # Test multiple log tags (e.g., request_id + IP)
  def test_multiple_log_tags
    uuid = "9c47c944-454b-4d70-9fed-667a07359467"
    log = <<~LOG
      [#{uuid}] [127.0.0.1] Started GET "/users" for ::1 at 2025-12-01 20:41:10 +0700
      [#{uuid}] [127.0.0.1] Processing by UsersController#index as HTML
      [#{uuid}] [127.0.0.1] Parameters: {"page" => "1"}
      [#{uuid}] [127.0.0.1]    User Load (0.5ms) SELECT * FROM users
      [#{uuid}] [127.0.0.1] Completed 200 OK in 50ms
    LOG
    output = run_parser(log)
    assert_match /c: UsersController/, output
    assert_match /a: index/, output
    assert_match /page:/, output
    assert_match /User Load/, output
    assert_match /s: 200/, output
  end

  # Test multiple log tags with lambda-based tag
  def test_multiple_log_tags_with_various_formats
    uuid = "abcd1234-5678-90ab-cdef-1234567890ab"
    log = <<~LOG
      [#{uuid}] [192.168.1.100] [custom_tag] Started POST "/orders" for 192.168.1.100
      [#{uuid}] [192.168.1.100] [custom_tag] Processing by OrdersController#create as JSON
      [#{uuid}] [192.168.1.100] [custom_tag] Parameters: {"item" => "widget"}
      [#{uuid}] [192.168.1.100] [custom_tag] Completed 201 Created in 100ms
    LOG
    output = run_parser(log)
    assert_match /c: OrdersController/, output
    assert_match /a: create/, output
    assert_match /item:/, output
    assert_match /s: 201/, output
    # First extra tag (IP) should be shown before the path
    assert_match /\[192\.168\.1\.100\].*POST/, output
  end

  # Test with 3 extra tags
  def test_three_extra_log_tags
    uuid = "aaaa1111-2222-3333-4444-555566667777"
    log = <<~LOG
      [#{uuid}] [10.0.0.1] [user:123] [session:abc] Started GET "/dashboard"
      [#{uuid}] [10.0.0.1] [user:123] [session:abc] Processing by DashboardController#show as HTML
      [#{uuid}] [10.0.0.1] [user:123] [session:abc] Completed 200 OK in 50ms
    LOG
    output = run_parser(log)
    assert_match /c: DashboardController/, output
    assert_match /a: show/, output
    assert_match /s: 200/, output
    # First extra tag should be shown
    assert_match /\[10\.0\.0\.1\].*GET/, output
  end

  # Test with IPv6 address tag
  def test_ipv6_log_tag
    uuid = "bbbb2222-3333-4444-5555-666677778888"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/api/status"
      [#{uuid}] [::1] Processing by ApiController#status as JSON
      [#{uuid}] [::1] Completed 200 OK in 5ms
    LOG
    output = run_parser(log)
    assert_match /c: ApiController/, output
    assert_match /a: status/, output
    assert_match /\[::1\].*GET/, output
  end

  # Test mixed: some requests with tags, some without
  def test_mixed_requests_with_and_without_tags
    uuid1 = "cccc3333-4444-5555-6666-777788889999"
    uuid2 = "dddd4444-5555-6666-7777-888899990000"
    log = <<~LOG
      [#{uuid1}] [192.168.1.50] Started GET "/with-ip"
      [#{uuid1}] [192.168.1.50] Processing by WithIpController#index as HTML
      [#{uuid1}] [192.168.1.50] Completed 200 OK in 10ms

      [#{uuid2}] Started GET "/no-ip"
      [#{uuid2}] Processing by NoIpController#index as HTML
      [#{uuid2}] Completed 200 OK in 10ms
    LOG
    output = run_parser(log)
    # Request with IP tag
    assert_match /\[192\.168\.1\.50\].*GET.*\/with-ip/, output
    assert_match /c: WithIpController/, output
    # Request without IP tag (no brackets before GET)
    assert_match /^GET \/no-ip$/m, output
    assert_match /c: NoIpController/, output
  end

  # Test custom log tags (Rails.logger.tagged) are preserved in log output
  def test_custom_log_tags_preserved
    uuid = "eeee5555-6666-7777-8888-999900001111"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/gatherings"
      [#{uuid}] [::1] Processing by GatheringsController#index as HTML
      [#{uuid}] [::1] [GatheringsIndex] ==> Loading gatherings for account 2
      [#{uuid}] [::1] Completed 200 OK in 100ms
    LOG
    output = run_parser(log)
    # System tag (IP) should appear in header
    assert_match /\[::1\].*GET/, output
    # Custom tag should appear with the log line
    assert_match /\[GatheringsIndex\].*==> Loading gatherings/, output
    # Log content should be present
    assert_match /account 2/, output
  end

  # Test system tags (appearing on most lines) are stripped from log output
  def test_system_tags_stripped_from_logs
    uuid = "ffff6666-7777-8888-9999-000011112222"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/users"
      [#{uuid}] [::1] Processing by UsersController#index as HTML
      [#{uuid}] [::1] ==> Debug message without custom tag
      [#{uuid}] [::1] Completed 200 OK in 50ms
    LOG
    output = run_parser(log)
    # System tag should appear in header
    assert_match /\[::1\].*GET/, output
    # Log line should NOT have ::1 tag (it's a system tag)
    assert_match /log:/, output
    assert_match %r{==>.*Debug message}, output
    # The ::1 should not appear next to the log message
    refute_match %r{\[::1\].*==>.*Debug}, output
  end

  # Test multiple custom tags on a single log line
  def test_multiple_custom_tags_on_log_line
    uuid = "11112222-3333-4444-5555-666677778888"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/orders"
      [#{uuid}] [::1] Processing by OrdersController#index as HTML
      [#{uuid}] [::1] [OrdersScope] [AdminOnly] ==> Filtering admin orders
      [#{uuid}] [::1] Completed 200 OK in 75ms
    LOG
    output = run_parser(log)
    # Both custom tags should appear
    assert_match /\[OrdersScope\]/, output
    assert_match /\[AdminOnly\]/, output
    assert_match %r{==>.*Filtering admin orders}, output
  end

  # Test log lines without any custom tags
  def test_log_line_without_custom_tags
    uuid = "22223333-4444-5555-6666-777788889999"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/posts"
      [#{uuid}] [::1] Processing by PostsController#index as HTML
      [#{uuid}] [::1] ==> Simple log message
      [#{uuid}] [::1] Completed 200 OK in 25ms
    LOG
    output = run_parser(log)
    # Log should appear without any tag prefix (since ::1 is system tag)
    assert_match /log:/, output
    assert_match %r{==>.*Simple log message}, output
  end

  # Test custom tags don't affect other log types (SQL, HTML, etc.)
  def test_custom_tags_only_affect_log_lines
    uuid = "33334444-5555-6666-7777-888899990000"
    log = <<~LOG
      [#{uuid}] [::1] Started GET "/items"
      [#{uuid}] [::1] Processing by ItemsController#index as HTML
      [#{uuid}] [::1] [CustomTag] ==> Custom tagged log
      [#{uuid}] [::1]    Item Load (0.5ms) SELECT * FROM items
      [#{uuid}] [::1]    Rendered items/index.html.erb (Duration: 5ms)
      [#{uuid}] [::1] Completed 200 OK in 50ms
    LOG
    output = run_parser(log)
    # Custom tag should only appear with log line
    assert_match /\[CustomTag\].*==> Custom tagged log/, output
    # SQL and HTML should not have the custom tag
    assert_match /Item Load/, output
    refute_match /\[CustomTag\].*Item Load/, output
    assert_match /items\/index\.html\.erb/, output
  end

  # Test tag frequency detection (system vs custom)
  def test_tag_frequency_detection
    uuid = "44445555-6666-7777-8888-999900001111"
    # IP tag appears on all 5 lines (100%), custom tag only on 1 line (20%)
    log = <<~LOG
      [#{uuid}] [10.0.0.1] Started GET "/dashboard"
      [#{uuid}] [10.0.0.1] Processing by DashboardController#show as HTML
      [#{uuid}] [10.0.0.1]    Dashboard Load (1.0ms) SELECT * FROM dashboards
      [#{uuid}] [10.0.0.1] [MetricsLog] ==> Calculating metrics
      [#{uuid}] [10.0.0.1] Completed 200 OK in 100ms
    LOG
    output = run_parser(log)
    # IP (system tag, >50% frequency) should be in header
    assert_match /\[10\.0\.0\.1\].*GET/, output
    # MetricsLog (custom tag, <50% frequency) should be with log line
    assert_match /\[MetricsLog\].*==> Calculating metrics/, output
  end

end
