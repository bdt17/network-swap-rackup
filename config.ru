#!/usr/bin/env ruby

require 'bundler/setup'
require_relative 'app'
require_relative 'auth'
require_relative 'fleet_simulator'

FleetSimulator.start! { App.broadcast_fleet! } unless ENV['RACK_ENV'] == 'test'

run App
