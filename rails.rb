#!/usr/bin/env ruby                                                              # Shebang line - tells the system to run this file with Ruby
# frozen_string_literal: true                                                    # Prevents string mutation for better performance
# NOTE: Requires Rails config.log_tags = [:request_id] to prefix logs with UUID  # This tool relies on request_id tags in logs

require 'shellwords'                                                             # Library for safe shell word escaping
require 'pastel'                                                                 # Library for terminal color output
require 'securerandom'                                                           # Library for generating random values (UUIDs)

module RailsLog                                                                  # Main module namespace for the log viewer
  # ============================================================================
  # CONFIGURATION - Edit values in this module to customize behavior
  # ============================================================================
  module Config
    # Defaults
    LOG_FILE  = "log/development.log"                                            # Default Rails log file path
    SLOW_MS   = 500                                                              # Threshold in ms for highlighting slow requests
    SHOW_TIME = false                                                            # Whether to show request duration by default

    # Patterns for matching log content
    RB    = /(?:app|lib)\/[\w\/\.]+\.rb:\d+/                                     # Regex to match Ruby file paths with line numbers
    HTML  = /Rendered/                                                           # Regex to match template render logs
    LOG   = /==>/                                                                # Regex to match debug log entries (use Rails.logger.debug "==> message")
    ERROR = /([A-Z]\w+Error|Exception|FATAL|Unpermitted parameters)/             # Regex to match error messages
    SQL   = / (Load|Update|Update All|Create|Destroy|Exists\?|Count) \(|SQL \(|TRANSACTION|BEGIN|COMMIT|ROLLBACK/  # Regex to match SQL queries

    # Patterns for parsing log structure (rarely need to change)
    REQUEST_LINE = /^\[([a-f0-9\-]+)\]\s+(.*)/                                   # Regex to extract UUID and content from log lines
    STARTED      = /^Started (\w+) "([^"]+)"/                                    # Regex to match request start (method + path)
    PROCESSING   = /Processing by ([^#]+)#(\w+)/                                 # Regex to match controller#action
    PARAMETERS   = /Parameters: (\{.*\})/                                        # Regex to match request parameters
    COMPLETED    = /^Completed (\d+) .* in (\d+)ms/                              # Regex to match request completion (status + duration)

    # Display labels - customize these to change output prefixes
    LABELS = {
      'controller' => 'c:',           # Controller name label
      'action'     => 'a:',           # Action name label
      'params'     => 'p:',           # Parameters label
      'sql'        => 'sql:',         # SQL queries label
      'log'        => 'log:',         # Debug log label
      'error'      => 'e:',           # Error message label
      'status'     => 's:',           # HTTP status label
      'rb'         => 'rb:',          # Ruby file paths label
      'html'       => 'html:'         # HTML template label
    }.freeze
  end

  # Global Pastel instance for coloring
  C = Pastel.new(enabled: true)                                                  # Create colorizer instance with colors enabled

  # ============================================================================
  # 1. LAUNCHER (Parent Process Logic)
  #    Handles CLI arguments, builds environment variables, and constructs
  #    the tail | grep pipeline.
  # ============================================================================
  class Launcher                                                                 # Class responsible for launching the log viewer
    attr_reader :options, :env_vars, :command_string                             # Expose options, env vars, and command as readable

    DEFAULTS = {                                                                 # Default options hash
      slow_ms: Config::SLOW_MS,                                                  # Default slow request threshold
      log_file: Config::LOG_FILE,                                                # Default log file path
      show_time: Config::SHOW_TIME,                                              # Default time display setting
      flags: [],                                                                 # Active display flags (empty = all)
      exclude: { 'global' => nil, 'path' => nil, 'controller' => nil, 'action' => nil, 'params' => nil, 'status' => nil, 'sql' => nil, 'log' => nil, 'error' => nil, 'controller_action' => nil },  # Exclusion patterns by type
      hide:    { 'rb' => nil, 'html' => nil, 'log' => nil, 'sql' => nil }        # Hide patterns by type (still process, just don't show)
    }.freeze                                                                     # Freeze to prevent modification

    ALL_FLAGS = %w[path controller action params rb html simple_sql sql sql_read sql_create sql_update sql_delete log error status].freeze  # All available display flags

    def initialize(argv)                                                         # Constructor taking command line arguments
      @argv = argv.dup                                                           # Duplicate argv to avoid modifying original
      # Deep copy defaults
      @options = Marshal.load(Marshal.dump(DEFAULTS))                            # Deep copy defaults to avoid mutation
    end

    def build!                                                                   # Build the launcher configuration
      parse_args                                                                 # Parse command line arguments
      check_file_exists!                                                         # Verify log file exists
      apply_default_flags if @options[:flags].empty?                             # Use all flags if none specified

      @env_vars = build_env                                                      # Build environment variables for child process
      @command_string = build_cmd                                                # Build the shell command to execute
      self                                                                       # Return self for method chaining
    end

    # Seams for testing
    def die!(msg); abort(msg); end                                               # Exit with error message (overridable for tests)
    def launch!(env, cmd); exec(env, cmd); end                                   # Execute command (overridable for tests)

    private                                                                      # Following methods are private

    def parse_args                                                               # Parse command line arguments
      while @argv.any?                                                           # Loop while arguments remain
        arg = @argv.shift                                                        # Get next argument
        key, val = arg.split('=', 2)                                             # Split on first '=' for key=value format
        # Handle em-dashes often caused by copy-pasting
        key = key.to_s.gsub(/^[—–]/, '--')                                       # Convert em-dashes to double hyphens

        case key                                                                 # Match argument type
        when '--slow-ms' then @options[:slow_ms] = (val || @argv.shift).to_i     # Set slow threshold (ms)
        when '--log-file' then @options[:log_file] = (val || @argv.shift)        # Set log file path
        when '--time' then @options[:show_time] = true                           # Enable time display
        when '--exclude', '-ex'                                                  # Global exclusion pattern
          add_val(:exclude, 'global', val || @argv.shift)                        # Add to global exclusions
        when /^--exclude-(path|controller|action|params|status|sql|log|error)$/  # Type-specific exclusion
          add_val(:exclude, Regexp.last_match(1), val || @argv.shift)            # Add to specific exclusion type
        when '--exclude-controller-action', '-exca'                              # Controller#action exclusion
          add_val(:exclude, 'controller_action', val || @argv.shift)             # Add to controller_action exclusions
        when /^--hide-(html|rb|log|sql)$/                                        # Type-specific hide pattern
          add_val(:hide, Regexp.last_match(1), val || @argv.shift)               # Add to specific hide type
        when '--include-flag', '--if'                                            # Specify which flags to show
          raw = (val || @argv.shift).to_s                                        # Get flag list value
          @options[:flags] = raw.split(',').map(&:strip)                         # Split and store flags
        end
      end
    end

    def add_val(category, key, val)                                              # Add value to exclusion/hide pattern
      current = @options[category][key]                                          # Get current pattern for this key
      @options[category][key] = current ? "#{current}|#{val}" : val.to_s         # Append with | or set new value
    end

    def check_file_exists!                                                       # Verify log file exists
      return if File.exist?(@options[:log_file])                                 # Return if file exists
      die!(C.red("❌ #{@options[:log_file]} missing"))                           # Exit with error if missing
    end

    def apply_default_flags                                                      # Apply all flags when none specified
      @options[:flags] = ALL_FLAGS                                               # Set flags to all available
    end

    def build_env                                                                # Build environment variables for child process
      env = @options[:flags].map { |k| ["S_#{k.upcase}", '1'] }.to_h             # Create S_FLAG=1 for each active flag
      env['S_SLOW_MS'] = @options[:slow_ms].to_s                                 # Pass slow threshold
      env['S_SHOW_TIME'] = @options[:show_time] ? '1' : nil                      # Pass time display setting
      @options[:exclude].each { |k, v| env["S_EX_#{k.upcase}"] = v if v }        # Pass exclusion patterns
      @options[:hide].each    { |k, v| env["S_HIDE_#{k.upcase}"] = v if v }      # Pass hide patterns
      env                                                                        # Return environment hash
    end

    def build_cmd                                                                # Build the shell command pipeline
      # The grep patterns allow the child process to receive only relevant lines
      base_pats = %w[Started Processing Completed Parameters]                    # Base patterns always needed
      dyn_pats = []                                                              # Dynamic patterns based on flags

      sql_flags = %w[simple_sql sql sql_read sql_create sql_update sql_delete]   # All SQL-related flags

      dyn_pats << Config::SQL.source if (@options[:flags] & sql_flags).any?      # Add SQL pattern if any SQL flag active
      dyn_pats << Config::LOG.source if @options[:flags].include?('log')         # Add LOG pattern if log flag active
      dyn_pats << Config::HTML.source if @options[:flags].include?('html')       # Add HTML pattern if html flag active
      dyn_pats << Config::ERROR.source                                           # Always include error pattern
      dyn_pats << "app/"                                                         # Catches stack traces in app directory

      pattern = (base_pats + dyn_pats).join('|')                                 # Join all patterns with OR

      # -a: treat binary as text, --line-buffered: flush immediately
      "tail -f #{@options[:log_file]} | grep -a --line-buffered -i -E '#{pattern}' | ruby #{File.expand_path(__FILE__)} -i"  # Build tail | grep | ruby pipeline
    end
  end

  # ============================================================================
  # 2. PROCESSOR (Child Process Logic)
  #    Reads filtered stream from STDIN, parses requests, and pretty prints.
  # ============================================================================
  class Processor                                                                # Class that processes and displays log lines
    def initialize                                                               # Constructor
      $stdout.sync = true                                                        # Disable output buffering for real-time display
      setup_signal_handlers                                                      # Handle Ctrl+C gracefully
      # Hash of UUID => Request Data
      # Using a Hash to satisfy test_buffer_rotation which inspects this ivar
      @req_buffer = Hash.new do |h, k|                                           # Hash with default block for new request data
        h[k] = {                                                                 # Create new request hash with empty arrays
          'rb' => [], 'html' => [], 'sql' => [], 'log' => [], 'error' => [],     # Arrays for each data type
          'source_found' => false                                                # Flag for error source tracking
        }
      end
      @slow_threshold = (ENV['S_SLOW_MS'] || 500).to_i                           # Get slow threshold from env or default
      @last_printed_sep = false                                                  # Track if separator was last printed
    end

    def run                                                                      # Main processing loop
      STDIN.each_line do |line|                                                  # Read each line from stdin
        process_line(line.strip)                                                 # Process the stripped line
      end
    rescue Interrupt                                                             # Handle Ctrl+C
      shutdown                                                                   # Clean shutdown
    end

    private                                                                      # Following methods are private

    def setup_signal_handlers                                                    # Setup handlers for graceful exit
      Signal.trap('INT') { shutdown }                                            # Handle Ctrl+C
      Signal.trap('TERM') { shutdown }                                           # Handle kill signal
    end

    def shutdown                                                                 # Clean shutdown
      puts "\n#{C.dim('Goodbye!')}"                                              # Print exit message
      exit 0                                                                     # Exit cleanly
    end

    # --- Text Utilities ---

    def strip_ansi(str)                                                          # Remove ANSI color codes from string
      str.gsub(/\e\[\d*(?:;\d+)*m/, '')                                          # Regex to match and remove escape sequences
    end

    def clean_line(str)                                                          # Clean up whitespace in log line
      str.gsub(/^\s*↳\s*/, '').gsub(/[[:space:]]+/, ' ').strip                   # Remove arrow prefix and normalize spaces
    end

    def draw_sep                                                                 # Draw separator line between requests
      return if @last_printed_sep                                                # Skip if separator was just printed
      puts C.dim('-' * 60)                                                       # Print dimmed 60-char separator
      @last_printed_sep = true                                                   # Mark separator as printed
    end

    def mark_printed                                                             # Mark that content was printed (not separator)
      @last_printed_sep = false                                                  # Reset separator flag
    end

    # --- Matching Utilities ---

    def matches?(env_key, val)                                                   # Check if value matches env pattern
      pattern = ENV[env_key]                                                     # Get pattern from environment
      return false if pattern.nil? || pattern.strip.empty?                       # Return false if no pattern

      begin
        val.match?(Regexp.new(pattern, Regexp::IGNORECASE))                      # Match case-insensitively
      rescue RegexpError
        # Fail safe for invalid regex in env vars (Test: test_invalid_regex_handling)
        false                                                                    # Return false on invalid regex
      end
    end

    def excluded?(type, val)                                                     # Check if value should be excluded
      matches?('S_EX_GLOBAL', val) || matches?("S_EX_#{type.upcase}", val)       # Check global and type-specific exclusions
    end

    def excluded_by_controller_action?(controller, action)                       # Check controller#action exclusion
      pattern = ENV['S_EX_CONTROLLER_ACTION']                                    # Get controller_action pattern
      return false if pattern.nil? || pattern.strip.empty? || controller.nil? || action.nil?  # Return false if missing data

      combined = "#{controller}##{action}"                                       # Combine controller and action
      pattern.split('|').any? do |p|                                             # Check each pattern (OR separated)
        begin
          combined.match?(Regexp.new(p.strip, Regexp::IGNORECASE))               # Match case-insensitively
        rescue RegexpError
          false                                                                  # Return false on invalid regex
        end
      end
    end

    def hidden?(type, val)                                                       # Check if value should be hidden
      matches?("S_HIDE_#{type.upcase}", val)                                     # Check type-specific hide pattern
    end

    # --- Core Processing Loop ---

    def process_line(raw)                                                        # Process a single log line
      raw = strip_ansi(raw)                                                      # Remove ANSI codes from input

      # Buffer Rotation
      @req_buffer.shift if @req_buffer.size > 50                                 # Remove oldest request if buffer full

      return unless raw =~ Config::REQUEST_LINE                                  # Skip lines without UUID prefix
      uuid, content = Regexp.last_match(1), clean_line(Regexp.last_match(2))     # Extract UUID and content

      request = @req_buffer[uuid]                                                # Get or create request data

      # If we see a "Started" line, but the previous request with this UUID
      # was already flushed (likely an error stack trace kept it alive), clean it up.
      if content =~ /^Started/ && @req_buffer.any? { |k, v| v[:flushed] && k != uuid }  # Check for stale flushed requests
        draw_sep                                                                 # Draw separator before cleanup
        @req_buffer.reject! { |k, v| v[:flushed] && k != uuid }                  # Remove stale requests
      end

      # Handle Post-Flush lines (Stack traces mostly)
      if request[:flushed]                                                       # If request already completed
        handle_post_flush_line(request, content)                                 # Handle as post-flush (stack trace)
        return                                                                   # Don't process further
      end

      # Parsing State Machine
      case content                                                               # Match content type
      when Config::STARTED                                                       # Request start line
        request.merge!(m: Regexp.last_match(1), p: Regexp.last_match(2))  # Store method and path
      when Config::PROCESSING                                                    # Controller processing line
        request.merge!(c: Regexp.last_match(1), a: Regexp.last_match(2))         # Store controller and action
      when Config::PARAMETERS                                                    # Parameters line
        request[:pm] = Regexp.last_match(1)                                      # Store parameters hash
      when Config::COMPLETED                                                     # Request completed line
        status = Regexp.last_match(1).to_i                                       # Extract HTTP status code
        duration = Regexp.last_match(2)                                          # Extract duration in ms

        flush_request(request, status, duration)                                 # Print the request output

        # If it's a server error, keep the request alive to catch the stack trace
        if status >= 400                                                         # Error status (4xx or 5xx)
          request[:flushed] = true                                               # Mark as flushed but keep for stack trace
        else
          draw_sep                                                               # Draw separator after successful request
          @req_buffer.delete(uuid)                                               # Remove completed request from buffer
        end
      else
        accumulate_data(request, content)                                        # Accumulate other data (SQL, logs, etc.)
      end
    end

    def accumulate_data(request, content)                                        # Accumulate data into request buffer
      if content =~ Config::RB                                                   # Ruby file reference
        val = content[/((?:app|lib)\/[\w\/\.]+\.rb:\d+)/, 1]                     # Extract file path with line number
        request['rb'] << val if val                                              # Add to rb array
      elsif content =~ Config::HTML                                              # Template render line
        request['html'] << content                                               # Add to html array
      elsif content =~ Config::ERROR                                             # Error message
        request['error'] << content                                              # Add to error array
      elsif content =~ Config::SQL                                               # SQL query
        request['sql'] << content                                                # Add to sql array
      elsif content =~ Config::LOG                                               # Debug log
        request['log'] << content                                                # Add to log array
      end
    end

    def handle_post_flush_line(request, content)                                 # Handle lines after request completed
      if content =~ Config::ERROR || content =~ /Error/                          # Error line in stack trace
        mark_printed                                                             # Mark as content printed
        puts "  #{C.red("e: #{content}")}"                                       # Print error in red
      elsif content.match?(/app\/|lib\//) && content.match?(/:\d+/) && !request[:source_found]  # Source file in stack trace
        if match = content.match(/((?:app\/|lib\/)[\w\/\.]+:\d+)/)               # Extract file path
          path = match[1]                                                        # Get the path
          unless hidden?('rb', path)                                             # Unless path is hidden
            request[:source_found] = true                                        # Mark source as found
            mark_printed                                                         # Mark as content printed
            puts "      #{C.red(path)}"                                          # Print path in red
          end
        end
      end
    end

    # --- Printing & Flushing ---

    def flush_request(req, status, duration)                                     # Print completed request
      return if req[:m].nil?                                                     # Skip incomplete requests (no method)

      # Exclusion Logic
      return if excluded?('path', req[:p]) ||                                    # Skip if path excluded
                excluded?('controller', req[:c]) ||                              # Skip if controller excluded
                excluded?('action', req[:a]) ||                                  # Skip if action excluded
                excluded?('params', req[:pm]) ||                                 # Skip if params excluded
                excluded?('status', status.to_s) ||                              # Skip if status excluded
                excluded_by_controller_action?(req[:c], req[:a])                 # Skip if controller#action excluded

      return if req['log'].any?   { |l| excluded?('log', l) } ||                 # Skip if any log line excluded
                req['sql'].any?   { |l| excluded?('sql', l) } ||                 # Skip if any SQL line excluded
                req['error'].any? { |l| excluded?('error', l) }                  # Skip if any error line excluded

      mark_printed                                                               # Mark as content printed

      status_int = status.to_i                                                   # Convert status to integer
      color = status_int < 300 ? :green : (status_int < 400 ? :yellow : :red)    # Green for 2xx, yellow for 3xx, red for 4xx+

      print_header(req, status_int, color)                                       # Print request header (method, path, controller, action)
      print_params(req)                                                          # Print parameters
      print_grouped(req, 'rb', :magenta)                                         # Print Ruby file references in magenta
      print_grouped(req, 'html', :red)                                           # Print template renders in red
      print_sql(req)                                                             # Print SQL queries
      print_errors(req)                                                          # Print errors
      print_logs(req)                                                            # Print debug logs
      print_footer(req, status_int, color, duration)                             # Print status and duration
    end

    def print_header(req, _status, _color)                                       # Print request header
      puts "#{C.white(req[:m])} #{req[:p]}" if ENV['S_PATH']                     # Print method and path if path flag set
      puts "  #{C.cyan(Config::LABELS['controller'])} #{C.cyan(req[:c])}" if ENV['S_CONTROLLER'] && req[:c]  # Print controller if flag set
      puts "  #{C.cyan(Config::LABELS['action'])} #{C.cyan(req[:a])}" if ENV['S_ACTION'] && req[:a]  # Print action if flag set
    end

    def print_params(req)                                                        # Print request parameters
      return unless ENV['S_PARAMS'] && req[:pm]                                  # Return if no params or flag not set

      puts "  #{C.yellow(Config::LABELS['params'])}"                              # Print params label
      begin
        # Use Ruby's eval to parse the params hash (safe here as it's from Rails logs)
        params = eval(req[:pm])                                                  # Parse params string to hash
        print_params_hash(params, 2)                                             # Print recursively with indent
      rescue SyntaxError, StandardError
        # Fallback: just print raw params if parsing fails
        puts "    #{C.yellow(req[:pm])}"                                         # Print raw params
      end
    end

    def print_params_hash(hash, indent)                                          # Recursively print params hash
      hash.each do |k, v|                                                        # Iterate each key-value pair
        next if indent == 2 && %w[controller action format].include?(k.to_s)     # Skip Rails internal params at top level
        prefix = '  ' * indent                                                   # Calculate indentation
        if v.is_a?(Hash)                                                         # Nested hash
          puts "#{prefix}#{C.yellow("#{k}:")}"                                   # Print key
          print_params_hash(v, indent + 1)                                       # Recurse into hash
        elsif v.is_a?(Array)                                                     # Array value
          puts "#{prefix}#{C.yellow("#{k}:")} #{C.yellow(v.inspect)}"            # Print array inline
        else                                                                     # Simple value
          puts "#{prefix}#{C.yellow("#{k}:")} #{C.yellow(v.to_s)}"               # Print key: value
        end
      end
    end

    def print_grouped(req, key, color)                                           # Print grouped items (rb or html)
      return unless ENV["S_#{key.upcase}"] && req[key].any?                      # Return if flag not set or no items

      paths = req[key].map do |x|                                                # Process each item
        x = x.gsub(/^\s*↳\s*/, '')                                               # Remove arrow prefix
        if key == 'html'                                                         # For HTML templates
          # Specific regex to match Rails "Rendered ..." lines, kept for test compatibility
          x[/Rendered (?:layout )?(?:collection of )?(.*?) /, 1]                 # Extract template path
        else                                                                     # For Ruby files
          x.gsub(/^app\/(controllers|models|views|services|helpers|components|policies|jobs|mailers|channels|serializers)\//, '')  # Remove app subdirectory prefix
        end
      end.compact.uniq.reject { |p| hidden?(key, p) }                            # Remove nils, duplicates, and hidden items

      return if paths.empty?                                                     # Return if no paths to show

      mark_printed                                                               # Mark as content printed
      puts "  #{C.send(color, Config::LABELS[key] || "#{key}:")}"                # Print section label

      # Group by directory for cleaner output
      paths.chunk_while { |i, j| File.dirname(i) == File.dirname(j) }.each do |chunk|  # Group consecutive items by directory
        dir = File.dirname(chunk.first)                                          # Get directory name
        if chunk.size >= 2 && dir != "."                                         # If multiple files in same directory
          puts "    #{C.send(color, "#{dir}/")}"                                 # Print directory name
          chunk.each { |path| puts "      #{C.send(color, File.basename(path))}" }  # Print just filenames indented
        else                                                                     # Single file or root directory
          chunk.each { |path| puts "    #{C.send(color, path)}" }                # Print full path
        end
      end
    end

    def classify_sql(line)                                                       # Classify SQL query type
      return [false, false, false, true, false] if line.match?(/TRANSACTION|BEGIN|COMMIT|ROLLBACK/i)  # Transaction control

      is_c = is_u = is_d = is_r = false                                          # Initialize flags for Create, Update, Delete, Read

      # Match "Model Load (0.1ms)" or "SQL (0.1ms)" headers
      if match = line.match(/(?:^|\s)([a-zA-Z]+) \(\d+\.\d+ms\)/)                # Match Rails SQL header format
        type = match[1]                                                          # Get operation type
        case type                                                                # Classify by type
        when 'Create', 'Insert' then is_c = true                                 # Create operation
        when 'Update' then is_u = true                                           # Update operation
        when 'Destroy', 'Delete' then is_d = true                                # Delete operation
        when 'Load', 'Count', 'Exists' then is_r = true                          # Read operation
        else
          # Fallback to checking the query body
          payload = line.sub(/^.*?ms\)\s+/, '')                                  # Extract query after header
          is_c = payload.match?(/^\s*INSERT/i)                                   # Check for INSERT
          is_u = payload.match?(/^\s*UPDATE/i)                                   # Check for UPDATE
          is_d = payload.match?(/^\s*DELETE/i)                                   # Check for DELETE
          is_r = payload.match?(/^\s*SELECT/i)                                   # Check for SELECT
        end
      else
        # Fallback for lines without Rails duration headers
        is_c = line.match?(/^\s*INSERT/i)                                        # Check for INSERT
        is_u = line.match?(/^\s*UPDATE/i)                                        # Check for UPDATE
        is_d = line.match?(/^\s*DELETE/i)                                        # Check for DELETE
        is_r = !is_c && !is_u && !is_d                                           # Default to read if not write
      end

      [is_c, is_u, is_d, false, is_r]                                            # Return [create, update, delete, transaction, read]
    end

    def print_sql(req)                                                           # Print SQL queries
      return unless req['sql'].any?                                              # Return if no SQL queries

      f_read, f_create, f_up, f_del = ENV['S_SQL_READ'], ENV['S_SQL_CREATE'], ENV['S_SQL_UPDATE'], ENV['S_SQL_DELETE']  # Get filter flags
      has_filters = f_read || f_create || f_up || f_del                          # Check if any filters active

      to_print = []                                                              # Array to collect printable queries

      req['sql'].uniq.each do |line|                                             # Process each unique SQL line
        next if hidden?('sql', line)                                             # Skip hidden queries

        is_c, is_u, is_d, is_tx, is_r = classify_sql(line)                       # Classify query type

        keep = if has_filters                                                    # If filters are active
                 (is_c && f_create) || (is_u && f_up) || (is_d && f_del) || (is_r && f_read)  # Keep only matching types
               else
                 ENV['S_SQL'] || ENV['S_SIMPLE_SQL']                             # Keep all if general SQL flag set
               end

        next unless keep                                                         # Skip if not keeping

        color = if is_c then :green                                              # Green for creates
                elsif is_u then :yellow                                          # Yellow for updates
                elsif is_d then :red                                             # Red for deletes
                elsif is_tx then :bright_black                                   # Gray for transactions
                else :cyan                                                       # Cyan for reads
                end

        to_print << { line: line, color: color }                                 # Add to print queue
      end

      return if to_print.empty?                                                  # Return if nothing to print

      puts "  #{C.blue(Config::LABELS['sql'])}"                                  # Print SQL section label
      to_print.each do |item|                                                    # Print each query
        l = item[:line]                                                          # Get line
        c = item[:color]                                                         # Get color

        if c == :bright_black                                                    # Transaction lines
          puts "    #{C.send(c, l.strip)}"                                       # Print simply
        elsif l =~ /^(.*?\([\d.]+ms\))/                                          # Lines with duration header
          # Shorten SQL: only show "Model Load (1.0ms)" part
          header = Regexp.last_match(1)                                          # Get header with duration
          formatted_header = header.gsub(/^(.*?)(\([\d.]+ms\))/) { "#{C.send(c, Regexp.last_match(1))}#{C.white(Regexp.last_match(2))}" }  # Color header, white duration
          puts "    #{formatted_header}"                                         # Print only header, no query
        else
          puts "    #{C.send(c, l.strip)}"                                       # Print simply colored
        end
      end
    end

    def print_errors(req)                                                        # Print error messages
      return unless ENV['S_ERROR'] && req['error'].any?                          # Return if no errors or flag not set
      puts "  #{C.red(Config::LABELS['error'])}"                                 # Print error section label
      req['error'].uniq.each { |x| puts "  #{C.red(x.strip)}" }                  # Print each error in red
    end

    def print_logs(req)                                                          # Print debug log entries
      return unless ENV['S_LOG'] && req['log'].any?                              # Return if no logs or flag not set
      puts "  #{C.green(Config::LABELS['log'])}"                                 # Print log section label
      req['log'].each do |x|                                                     # Process each log entry
        c = x.gsub(/^\s*↳\s*/, '').strip                                         # Clean up the log line
        puts "  #{C.green(c)}" unless hidden?('log', c)                          # Print in green unless hidden
      end
    end

    def print_footer(req, status, color, duration)                               # Print request footer with status and duration
      d_ms = duration.to_i                                                       # Convert duration to integer
      status_str = "  #{C.send(color, "#{Config::LABELS['status']} #{status}")}" # Format status with color

      if d_ms >= @slow_threshold                                                 # If request is slow
        puts "#{status_str} #{C.white.on_red.bold(" #{d_ms}ms ")}"               # Print with highlighted red background
      elsif ENV['S_SHOW_TIME']                                                   # If time display enabled
        puts "#{status_str} #{C.dim("(#{d_ms}ms)")}"                             # Print with dimmed duration
      else
        puts status_str                                                          # Print just status
      end
    end
  end

  # ============================================================================
  # 3. ENTRY POINT
  # ============================================================================
  def self.start(args)                                                           # Main entry point method
    if args[0] == '-i'                                                           # If running as child process (internal mode)
      RailsLog::Processor.new.run                                                # Start the processor to read from stdin
    else                                                                         # If running as parent process
      launcher = RailsLog::Launcher.new(args).build!                             # Build launcher with CLI args

      puts RailsLog::C.bold.cyan("\n🚀 Rails Log Launcher")                      # Print startup banner
      puts "   #{RailsLog::C.yellow('Active Flags:')}  #{launcher.options[:flags].join(', ')}"  # Print active flags

      active_ex = launcher.options[:exclude].select { |_, v| v }                 # Get active exclusions
      if active_ex.any?                                                          # If any exclusions set
        puts "   #{RailsLog::C.red('EXCLUDE (Kill):')} #{active_ex.map { |k, v| "#{k}=/#{v}/" }.join(', ')}"  # Print exclusion patterns
      end

      active_hide = launcher.options[:hide].select { |_, v| v }                  # Get active hide patterns
      if active_hide.any?                                                        # If any hide patterns set
        puts "   #{RailsLog::C.dim('HIDE (Clean):')}     #{active_hide.map { |k, v| "#{k}=/#{v}/" }.join(', ')}"  # Print hide patterns
      end

      puts RailsLog::C.dim('-' * 60)                                             # Print separator line

      launcher.launch!(launcher.env_vars, launcher.command_string)               # Execute the tail | grep | ruby pipeline
    end
  end
end

RailsLog.start(ARGV) if __FILE__ == $0                                           # Start the program if run directly
