# rlog

A concise, quick-glance overview of your Rails logs.

![rlog demo](~/Desktop/apps/Obsidian/Personal/CleanShot/rlog.png)

Run it alongside `rails server` in a separate terminal - use rlog for the overview, switch to server output when you need full details.

## Compare to Rails

**Rails:**
```
Started PUT /users/123 ...
Started PUT /users/456 ...
Processing by UsersController ...
  User Load (0.5ms) SELECT "users"...
Processing by UsersController ...
Completed 200 OK ...
```

**rlog:**
```
PUT /users/123
  c: UsersController
  a: update
  p:
    name: "John"
    email: "john@example.com"
  rb:
    controllers/users_controller.rb
    models/user.rb
  html:
    users/
      edit.html.erb
      _form.html.erb
    shared/_header.html.erb
  sql:
    User Load (0.5ms)
  log:
    ==> line 10: @user: #<User id: 123>
    ==> line 15: @user.valid?: true
    ==> line 20: @user.save: true
  e:
    NoMethodError: undefined method 'foo'
      app/models/user.rb:42
  s: 500 (45ms)
```

## Features

- No more mixed-up logs from multiple requests
- Shows grouped logs
- Filters: include, exclude, or hide patterns
- Groups files by directory
- Captures stack traces with errors
- Highlights slow requests
- Shortens SQL to show what's needed
- SQL filtering by CRUD type

## Installation

```bash
gem install pastel
git clone https://github.com/tednguyendev/rlog.git ~/.rlog
echo 'alias rlog="ruby ~/.rlog/rails.rb"' >> ~/.zshrc
```

Requires request IDs in your log. Add to `config/environments/development.rb`:

```ruby
config.log_tags = [:request_id]
```

## Examples

```bash
# Full view with SQL
rlog --include-flag path,log,controller,action,html,error,status,params,rb,sql

# Compact view
rlog --include-flag path,log,controller,action,error,status,simple_sql

# Minimal: just paths and logs
rlog --include-flag path,log

# Highlight slow requests
rlog --slow-ms 100

# Different log file
rlog --log-file log/prod.log
```

## Options

Available flags: `path`, `controller`, `action`, `params`, `rb`, `html`, `sql`, `simple_sql`, `sql_read`, `sql_create`, `sql_update`, `sql_delete`, `log`, `error`, `status`

| Option | Description | Example |
|--------|-------------|---------|
| `--include-flag FLAGS` | Comma-separated list of what to show | `path,sql,status` |
| `--slow-ms N` | Highlight requests >= N ms (default: 500) | `100` |
| `--time` | Show duration for all requests | |
| `--log-file PATH` | Custom log file path | `log/prod.log` |
| `--exclude REGEX` | Exclude requests matching any field | `health` |
| `--exclude-path REGEX` | Exclude by path | `/api\|/cable` |
| `--exclude-controller REGEX` | Exclude by controller | `HealthController` |
| `--exclude-action REGEX` | Exclude by action | `index` |
| `--exclude-params REGEX` | Exclude by parameters | `token` |
| `--exclude-status REGEX` | Exclude by status code | `304` |
| `--exclude-sql REGEX` | Exclude by SQL content | `Session` |
| `--exclude-log REGEX` | Exclude by log content | `cache` |
| `--exclude-error REGEX` | Exclude by error content | `Timeout` |
| `--exclude-controller-action REGEX` | Exclude by Controller#action | `Health#index` |
| `--hide-rb REGEX` | Hide matching stack traces | `gems/` |
| `--hide-sql REGEX` | Hide matching SQL | `Session` |
| `--hide-log REGEX` | Hide matching logs | `debug` |
| `--hide-html REGEX` | Hide matching renders | `shared/\|layouts/` |

## How It Works

Runs `tail -f | grep | ruby` - tails the log, filters relevant lines, buffers by request UUID, prints when complete.

## License

MIT
