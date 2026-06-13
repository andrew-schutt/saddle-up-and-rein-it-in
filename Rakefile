require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "final"
  t.test_files = FileList["final/test/*_test.rb"]
  t.warning = false
end

task default: :test
