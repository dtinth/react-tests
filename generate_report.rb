require 'json'

TestResult = Struct.new(:git_revision, :version) do
  def url
    "https://github.com/facebook/react/tree/#{git_revision}"
  end

  def blob_url
    "https://github.com/facebook/react/tree/#{git_revision}"
  end

  def data
    @data ||= JSON.parse(File.read("data/react-tests-#{git_revision}-stable.json"))
  end

  def total_test_suites
    data['numTotalTestSuites']
  end

  def total_tests
    data['numTotalTests']
  end

  def test_names
    @test_names ||= data['testResults'].flat_map { |r| r['assertionResults'].map { |a| a['fullName'] } }
  end

  def report_filename
    "#{version}.md"
  end

  def suite_names
    @suite_names ||= (data['testResults'].map { |r| r['name'] }).sort
  end

  def suite(name)
    TestSuite.new(self, data['testResults'].find { |r| r['name'] == name })
  end

  def generate_report
    filename = report_filename
    File.open "reports/#{filename}", 'w' do |out|
      out.puts "# [#{version}](#{url})"
      out.puts
      writer = AncestralWriter.new(out)
      suite_names.each do |suite_name|
        suite = suite(suite_name)
        out.puts "- `#{suite.name}`"
        suite.tests.each do |test|
          writer.write test.ancestor_titles, "- #{test.link}"
        end
      end
    end
  end
end

TestSuite = Struct.new(:test_result, :data) do
  def found?
    !data.nil?
  end

  def name
    return nil unless data
    data['name'].sub('/home/runner/work/react-tests/react-tests/react/', '')
  end

  def test_names
    return [] unless data
    @test_names ||= tests.map { |r| r.full_name }
  end

  def grouping_key
    return nil unless data
    path_segments = name.split('/')
    package_name = path_segments.take(2).join('/')
    sort_key = begin
      if package_name == 'packages/react'
        0
      elsif package_name == 'packages/react-dom'
        1
      elsif package_name =~ /^packages\/(react-reconciler|react-test-renderer|scheduler)/
        2
      elsif package_name =~ /^packages\/react-devtools/
        93
      elsif package_name =~ /^packages\/react-/
        92
      else
        99
      end
    end
    [sort_key, package_name]
  end

  def tests
    return [] unless data
    @tests ||= data['assertionResults']
      .filter { |r| r['status'] == 'passed' }
      .reject { |r| r['fullName']['[GATED, SHOULD FAIL]'] }
      .map { |r| Test.new(self, r) }
  end

  def url
    "#{test_result.blob_url}/#{name}"
  end
end

Test = Struct.new(:test_suite, :data) do
  def full_name
    data['fullName']
  end

  def ancestor_titles
    data['ancestorTitles']
  end

  def url
    test_suite.url + "#L#{data['location']['line']}"
  end

  def link_name
    data['title'].strip.lines.first.strip
  end

  def link
    "[#{link_name}](#{url})"
  end
end

test_results = [
  TestResult.new('v17.0.0', 'v17.0.0'),
  TestResult.new('v17.0.1', 'v17.0.1'),
  TestResult.new('v17.0.2', 'v17.0.2'),
  TestResult.new('e6be2d531', 'v18.0.0-alpha'),
  TestResult.new('96ca8d915', 'v18.0.0-beta'),
  TestResult.new('f2a59df48', 'v18.0.0-rc.0'),
]

comparisons = []

Comparison = Struct.new(:current, :previous) do
  def changes_count
    added = current.test_names - previous.test_names
    removed = previous.test_names - current.test_names
    [added.size, removed.size]
  end

  def report_filename
    return nil unless previous
    added, removed = changes_count
    return nil if added == 0 && removed == 0
    "#{previous.version}_VS_#{current.version}.md"
  end

  def changes
    return '-' unless previous
    added, removed = changes_count
    filename = report_filename
    text = "+#{added}, -#{removed}"
    filename ? "[#{text}](#{filename})" : text
  end

  def suite_names
    @suite_names ||= (current.suite_names | previous.suite_names).sort
  end

  def comparisons
    suite_names
      .map { |s| SuiteComparison.new(current.suite(s), previous.suite(s)) }
      .select(&:changed?)
  end

  def generate_report
    filename = report_filename
    return unless filename
    File.open "reports/#{filename}", 'w' do |out|
      out.puts "# Test comparison between React #{previous.version} and #{current.version}"
      comparisons.group_by(&:grouping_key).sort.each do |(_sort_key, group_title), group|
        out.puts
        out.puts "## #{group_title}"
        group.each do |comparison|
          out.puts "- `#{comparison.suite_name}`"
          writer = AncestralWriter.new(out)
          comparison.added.each do |test|
            writer.write test.ancestor_titles, "- (+) #{test.link}"
          end
          writer = AncestralWriter.new(out)
          comparison.removed.each do |test|
            writer.write test.ancestor_titles, "- (-) #{test.link}"
          end
        end
      end
    end
  end
end

class AncestralWriter
  def initialize(out)
    @out = out
    @current = []
  end

  def write(ancestor_titles, text)
    longest_common_size = @current.zip(ancestor_titles).take_while { |a, b| a == b }.size
    while @current.size > longest_common_size
      @current.pop
    end
    while @current.size < ancestor_titles.size
      @current << ancestor_titles[@current.size]
      @out.puts "  " * @current.size + '- ' + @current.last
    end
    @out.puts "  " * (@current.size + 1) + text
  end
end

# Comparisons of suite with same name
SuiteComparison = Struct.new(:current, :previous) do
  def suite_name
    current.name || previous.name
  end

  def suite
    current.found? ? current : previous
  end

  def grouping_key
    suite.grouping_key
  end

  def changed?
    added.size > 0 || removed.size > 0
  end

  def added
    previous_names = previous.test_names
    current.tests.select { |t| !previous_names.include?(t.full_name) }
  end

  def removed
    current_names = current.test_names
    previous.tests.select { |t| !current_names.include?(t.full_name) }
  end
end

File.open 'reports/README.md', 'w' do |out|
  out.puts "| Version | Suites | Tests | Compared to<br>previous | Compared to<br>v17.0.2 |"
  out.puts "| --- | ---:| ---:| ---:| ---:|"
  last = nil
  v17 = nil
  test_results.each do |r|
    compare_last = Comparison.new(r, last)
    compare_v17 = Comparison.new(r, v17)
    cols = [
      "[#{r.version}](#{r.url})",
      "#{r.total_test_suites}",
      "[#{r.total_tests}](#{r.report_filename})",
      compare_last.changes,
      compare_v17.changes,
    ]
    out.puts "| #{cols * ' | '} |"
    last = r
    v17 = r if r.version == 'v17.0.2'
    comparisons << compare_last
    comparisons << compare_v17
  end
end

comparisons.each do |c|
  c.generate_report
end

test_results.each do |t|
  t.generate_report
end