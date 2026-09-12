# Runs every *_test.rb under test/. `ruby file1 file2` treats file2 as an
# ARGV string, not a second file to load, so plain `ruby test/a_test.rb
# test/b_test.rb` silently only runs the first - use this instead:
#   bundle exec ruby -Itest test/run.rb
Dir[File.expand_path('*_test.rb', __dir__)].sort.each { |f| require f }
