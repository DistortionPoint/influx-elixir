unless Mix.env() == :test do
  Mix.raise("Tests must run in the :test environment. Got: #{Mix.env()}")
end

ExUnit.start(exclude: [:integration, :v2, :v3_core, :v3_enterprise])
