defmodule GuardianDb do
  @moduledoc """
  GuardianDb is a simple module that hooks into guardian to prevent playback of tokens.

  In vanilla Guardian, tokens aren't tracked so the main mechanism that exists to make a token inactive is to set the expiry and wait until it arrives.

  GuardianDb takes an active role and stores each token in the database verifying it's presense (based on it's jti) when Guardian verifies the token.
  If the token is not present in the DB, the Guardian token cannot be verified.

  Provides a simple database storage and check for Guardian tokens.

  - When generating a token, the token is stored in a database.
  - When tokens are verified (channel, session or header) the database is checked for an entry that matches. If none is found, verification results in an error.
  - When logout, or revoking the token, the corresponding entry is removed
  """
  use Guardian.Hooks

  defmodule Token do
    @moduledoc """
    A very simple model for storing tokens generated by guardian.
    """

    use Ecto.Schema
    @primary_key {:jti, :string, autogenerate: false }
    @schema_name Keyword.get(Application.get_env(:guardian_db, GuardianDb), :schema_name) || "guardian_tokens"
    @schema_prefix Keyword.get(Application.get_env(:guardian_db, GuardianDb), :prefix) || nil

    import Ecto.Changeset
    import Ecto.Query

    schema @schema_name do
      field :typ, :string
      field :aud, :string
      field :iss, :string
      field :sub, :string
      field :exp, :integer
      field :jwt, :string
      field :claims, :map

      timestamps
    end

    @doc """
    Find one token by matching jti and aud
    """
    def find_by_claims(claims) do
      jti = Dict.get(claims, "jti")
      aud = Dict.get(claims, "aud")
      GuardianDb.repo.get_by(Token, jti: jti, aud: aud)
    end

    @doc """
    Create a new new token based on the JWT and decoded claims
    """
    def create!(claims, jwt) do
      prepared_claims = claims |> Dict.put("jwt", jwt) |> Dict.put("claims", claims)
      GuardianDb.repo.insert cast(%Token{}, prepared_claims, [:jti, :typ, :aud, :iss, :sub, :exp, :jwt, :claims])
    end

    @doc """
    Purge any tokens that are expired. This should be done periodically to keep your DB table clean of clutter
    """
    def purge_expired_tokens! do
      timestamp = Guardian.Utils.timestamp
      from(t in Token, where: t.exp < ^timestamp) |> GuardianDb.repo.delete_all
    end
  end

  if !Keyword.get(Application.get_env(:guardian_db, GuardianDb), :repo), do: raise "GuardianDb requires a repo"

  @doc """
  After the JWT is generated, stores the various fields of it in the DB for tracking
  """
  def after_encode_and_sign(resource, type, claims, jwt) do
    case Token.create!(claims, jwt) do
      { :error, _ } -> { :error, :token_storage_failure }
      _ -> { :ok, { resource, type, claims, jwt } }
    end
  end

  @doc """
  When a token is verified, check to make sure that it is present in the DB.
  If the token is found, the verification continues, if not an error is returned.
  """
  def on_verify(claims, jwt) do
    case Token.find_by_claims(claims) do
      nil -> { :error, :token_not_found }
      _token -> { :ok, { claims, jwt } }
    end
  end

  @doc """
  When logging out, or revoking a token, removes from the database so the token may no longer be used
  """
  def on_revoke(claims, jwt) do
    model = Token.find_by_claims(claims)
    if model do
      case repo.delete(model) do
        { :error, _ } -> { :error, :could_not_revoke_token }
        nil -> { :error, :could_not_revoke_token }
        _ -> { :ok, { claims, jwt } }
        end
    else
      { :ok, { claims, jwt } }
    end
  end

  def repo do
    Dict.get(Application.get_env(:guardian_db, GuardianDb), :repo)
  end
end
