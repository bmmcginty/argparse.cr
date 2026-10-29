require "./spec_helper"
require "./support/cpython_cases"

# Conformance suite derived from CPython's `Lib/test/test_argparse.py`.
#
# Every example below corresponds to a `ParserTestCase` subclass upstream: the
# parser definition, the accepted command lines with the namespace they must
# produce, and the rejected command lines.  Regenerate the fixture with
# `python3 spec/support/extract_python_cases.py --output spec/fixtures/cpython_test_argparse.json`.
describe "CPython test_argparse" do
  CpythonCases.cases.each do |test_case|
    describe test_case.name do
      test_case.successes.each do |argv, expected|
        it "parses #{argv.inspect}" do
          namespace = test_case.build_parser.parse_args(argv)
          namespace.to_h.should eq(expected)
        end
      end

      test_case.failures.each do |argv|
        it "rejects #{argv.inspect}" do
          expect_raises(Argparse::ArgumentError) do
            test_case.build_parser.parse_args(argv)
          end
        end
      end

      it "parses every accepted command line in one parser" do
        parser = test_case.build_parser
        test_case.successes.each do |argv, expected|
          parser.parse_args(argv).to_h.should eq(expected)
        end
      end
    end
  end
end
