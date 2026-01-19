defmodule Mydia.RemoteAccess.ResumeClaims do
  use Task

  def start_link(_arg) do
    Task.start_link(&run/0)
  end

  def run do
    # Wait for other services to be ready
    Process.sleep(5000)

    Mydia.RemoteAccess.resume_active_claims()
  end
end
