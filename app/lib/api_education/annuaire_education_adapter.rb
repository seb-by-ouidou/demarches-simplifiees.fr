require 'json_schemer'

class ApiEducation::AnnuaireEducationAdapter
  class InvalidSchemaError < ::StandardError
    def initialize(errors)
      super(errors.map(&:to_json).join("\n"))
    end
  end

  def initialize(id)
    @id = id
  end

  def to_params
    record = data_source[:records].first
    if record.present?
      properties = record[:fields].merge({ geometry: record[:geometry] }).deep_stringify_keys
      if schemer.valid?(properties)
        properties
      else
        errors = schemer.validate(properties).to_a
        raise InvalidSchemaError.new(errors)
      end
    end
  end

  private

  def data_source
    @data_source ||= JSON.parse(ApiEducation::API.get_annuaire_education(@id), symbolize_names: true)
  end

  def schemer
    @schemer ||= JSONSchemer.schema(Rails.root.join('app/schemas/etablissement-annuaire-education.json'))
  end
end
