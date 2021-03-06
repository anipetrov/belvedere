class Funnel
  include Mongoid::Document
  include Mongoid::Timestamps



  field :name, type: String
  field :project, type: String
  field :events, type: Array

  validates_uniqueness_of :name

  def self.create_from_params!(params)
    events = params.select { |k,v| k[/events-input-/] }.values
    funnel = new(name: params['name'], project: params['project'], events: events)
    funnel.save
    funnel
  end

  def sql(date_range, days_to_complete)
    days_ago = date_range[/\d+/]
    days_to_complete = days_to_complete[/\d+/]

    ctes = events.map.with_index do |event, i|
      <<-SQL
        #{event} AS
          ( select anonymous_id, received_at
            from #{project}_production.#{event}
            where received_at > DATEADD('day', -#{days_ago}, CURRENT_DATE)
            #{ i > 0 ? "and anonymous_id in (select anonymous_id from #{events[i -1]})" : ''}
          )
      SQL
    end

    ctes += events.map.with_index do |event, i|
      previous = "inner join time_constrained_#{events[i-1]} tc0 on tc0.anonymous_id = #{event}.anonymous_id 
                  and first_event.received_at > tc0.received_at"
      next if i == 0
      <<-SQL
        time_constrained_#{event} AS 
          ( select #{event}.anonymous_id, #{event}.received_at
            from #{event}
            inner join #{events[0]} first_event on #{event}.anonymous_id = first_event.anonymous_id
              and #{event}.received_at > first_event.received_at
              and dateadd('day', -#{days_to_complete}, #{event}.received_at) <= first_event.received_at
            #{i > 1 ? previous : ''}
          )
      SQL
    end.compact

    main_body = events.map.with_index do |event, i|
      <<-SQL
        select '#{event}' AS event, count(distinct anonymous_id)
        from #{i > 0 ? 'time_constrained_' : ''}#{event}
      SQL
    end

    "WITH #{ctes.join(',')} #{main_body.join(%(UNION ALL\n))}"
  end
end
