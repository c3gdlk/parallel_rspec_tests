# parallel_rspec_tests

When you developing a complex feature which goes through all your architecture it's really important to run all tests as many times as possible.

A parallel tests in 200 LoC. The main benefits - all code are stuped simple, so it's easy to maintain and configure for another project.

## Dependencies

It works via [overmind] (https://github.com/DarthSim/overmind), so you need to install it first

## Usage

0. Copy any of `smoke_<n>.rake` files to your project

1. Add ENV to your `database.yml`

```
database: <%= ENV['DB_NAME'] %>_test<%= ENV['TEST_ENV_NUMBER'] %>
```

2. Configure capybara server

`Capybara.server_port = 9887 + ENV['TEST_ENV_NUMBER'].to_i`

3. Setup

```
rake smoke:create
rake smoke:prepare
```

4. Run

```
rake smoke:run
```

## Calibration

It has a task for calibration, but I didn't found it very usefull. In my case it has some benefits, but didn't worth to spent a hour for calibration.

