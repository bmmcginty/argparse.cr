require "./spec_helper"
require "./support/cpython_cases"

# Usage/help formatting conformance derived from CPython's `HelpTestCase`
# classes.  Each example compares `format_usage` and `format_help` byte for byte
# with the text CPython produces for the same parser definition.
describe "CPython test_argparse help formatting" do
  CpythonCases.help_cases.each do |help_case|
    describe help_case.name do
      it "formats the usage message" do
        help_case.build_parser.format_usage.should eq(help_case.usage)
      end

      it "formats the help message" do
        help_case.build_parser.format_help.should eq(help_case.help_text)
      end
    end
  end
end
