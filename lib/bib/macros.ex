defmodule Bib.Macros do
  defguard is_info_hash(info_hash) when is_binary(info_hash) and byte_size(info_hash) == 20
end
