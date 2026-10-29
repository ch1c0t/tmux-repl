require_relative "helper"

describe "CLI" do
  it "prints a help message" do
    stdout, = cli("--help")

    expect(stdout).to start_with("crystal.cli_project is a CLI made with Crystal.")
  end
end
