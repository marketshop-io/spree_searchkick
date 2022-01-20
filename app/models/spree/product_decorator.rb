module Spree::ProductDecorator
  def self.prepended(base)
    base.searchkick(
      callbacks: :async,
      word_start: [:name],
      settings: { number_of_replicas: 0 },
      merge_mappings: true,
      mappings: {
        properties: {
          properties: {
            type: 'nested'
          }
        }
      }
    ) unless base.respond_to?(:searchkick_index)

    base.scope :search_import, lambda {
      includes(
        :option_types,
        :variants_including_master,
        taxons: :taxonomy,
        master: :default_price,
        product_properties: :property,
        variants: :option_values
      )
    }

    def base.autocomplete_fields
      ['taxon_names^7', 'name^5', 'description', 'skus', 'partnumber^2', 'manufacturer^3']
    end

    def base.search_fields
      ['taxon_names^7', 'name^5', 'description', 'skus', 'partnumber^2', 'manufacturer^3']
    end

    def base.autocomplete(keywords, store_id)
      if keywords
        Spree::Product.search(
          keywords,
          fields: autocomplete_fields,
          match: :word_start,
          limit: 10,
          load: false,
          misspellings: { below: 3 },
          where: search_where(store_id),
        ).map { |p| "#{p.name.strip}:::#{p.slug}"}.uniq
      else
        Spree::Product.search(
          "*",
          fields: autocomplete_fields,
          load: false,
          misspellings: { below: 3 },
          where: search_where(store_id),
        ).map { |p| "#{p.name.strip}:::#{p.slug}"}
      end
    end

    def base.search_where(store_id)
      {
        active: true,
        in_stock: true,
        price: { not: nil },
        store_ids: store_id,
        vendor_id: Spree::Vendor.active.pluck(:id)
      }
    end

    # Searchkick can't be reinitialized, this method allow to change options without it
    # ex add_searchkick_option { settings: { "index.mapping.total_fields.limit": 2000 } }
    def base.add_searchkick_option(option)
      base.class_variable_set(:@@searchkick_options, base.searchkick_options.deep_merge(option))
    end
  end

  def search_data
    all_variants = variants_including_master.map { |v| [v.id, v.sku_without_prefix] }

    all_taxons = taxons.flat_map { |t| t.self_and_ancestors.pluck(:id, :name) }.uniq

    json = {
      id: id,
      name: name,
      slug: slug,
      description: description,
      active: available?,
      in_stock: in_stock?,
      created_at: created_at,
      updated_at: updated_at,
      price: price,
      currency: currency,
      conversions: orders.complete.count,
      taxon_ids: all_taxons.map(&:first),
      taxon_names: all_taxons.map(&:last),
      skus: all_variants.map(&:last),
      total_on_hand: total_on_hand,
      counties: counties

    }

    json.merge!(option_types_for_es_index(all_variants))
    json.merge!(properties_for_es_index)
    json.merge!(index_data)

    json
  end

  def option_types_for_es_index(all_variants)
    filterable_option_types = option_types.filterable.pluck(:id, :name)
    option_value_ids = ::Spree::OptionValueVariant.where(variant_id: all_variants.map(&:first)).pluck(:option_value_id).uniq
    option_values = ::Spree::OptionValue.where(
      id: option_value_ids, 
      option_type_id: filterable_option_types.map(&:first)
    ).pluck(:option_type_id, :name)

    json = {
      option_type_ids: filterable_option_types.map(&:first),
      option_type_names: filterable_option_types.map(&:last),
      option_value_ids: option_value_ids
    }

    filterable_option_types.each do |option_type|
      values = option_values.find_all { |ov| ov.first == option_type.first }.map(&:last).uniq.compact.each(&:downcase)

      json.merge!(Hash[option_type.last.downcase, values]) if values.present?
    end

    json
  end

  def properties_for_es_index
    filterable_properties = properties.filterable.pluck(:id, :name)
    properties_values = product_properties.where(property_id: filterable_properties.map(&:first)).pluck(:property_id, :value)

    filterable_properties = filterable_properties.map do |prop|
      {
        id: prop.first,
        name: prop.last,
        value: properties_values.find { |pv| pv.first == prop.first }&.last
      }
    end

    json = { property_ids: filterable_properties.map { |p| p[:id] } }
    json.merge!(property_names: filterable_properties.map { |p| p[:name] })
    json.merge!(properties: filterable_properties)

    filterable_properties.each do |prop|
      json.merge!(Hash[prop[:name].downcase, prop[:value].downcase]) if prop[:value].present?
    end

    json
  end

  def index_data
    {
      vendor_id: vendor_id,
      manufacturer: manufacturer,
      partnumber: partnumber,
      store_ids: store_ids,
      counties: counties
    }
  end
end

Spree::Product.prepend(Spree::ProductDecorator)
