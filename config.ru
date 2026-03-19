require 'rack'
require 'json'
require 'stripe'
Stripe.api_key = ENV['STRIPE_SECRET_KEY'] || 'sk_test_...' # Add to Render Environment

# Request counter for metrics
$request_count = 0
$start_time = Time.now

begin
  require 'pg'
  $DB = ENV['DATABASE_URL'] ? PG.connect(ENV['DATABASE_URL']) : nil
rescue => e
  $DB = nil
end

app = lambda do |env|
  $request_count += 1
  
  case env['PATH_INFO']
  when '/'
    [200, {'Content-Type' => 'text/html; charset=utf-8'}, ['<h1>🚁 Thomas IT Drone Fleet + 💳 Stripe</h1><p>Requests: ' + $request_count.to_s + ' | <a href="/metrics">Metrics</a> | <a href="/billing">Stripe</a>']]
    
  when '/health'
    [200, {'Content-Type' => 'application/json'}, [JSON.generate({
      status: 'healthy', 
      service: 'live',
      requests: $request_count,
      uptime: ((Time.now - $start_time)/3600).round(1)
    })]]
    
  when '/metrics'
    uptime = ((Time.now - $start_time)/3600).round(2)
    [200, {'Content-Type' => 'text/plain'}, ["puma_workers:2|uptime:#{uptime*100}|requests:#{$request_count}|db:#{$DB ? 'connected' : 'pending'}"]]
    
  when '/billing'
    begin
      # Create test customer (pharma billing)
      customer = Stripe::Customer.create({
        name: 'Thomas IT Pharma',
        email: 'billing@thomasit.com',
        description: 'Drone Cold Chain Service'
      })
      [200, {'Content-Type' => 'application/json'}, [JSON.generate({
        status: 'success',
        customer_id: customer.id,
        message: 'Pharma billing customer created'
      })]]
    rescue Stripe::StripeError => e
      [400, {'Content-Type' => 'application/json'}, [JSON.generate({error: e.message})]]
    end
    
  when '/invoice'
    begin
      # Generate pharma shipment invoice
      invoice = Stripe::Invoice.create({
        customer: 'cus_TEST123', # Replace with real customer ID
        items: [{
          description: 'Insulin Cold Chain Delivery (DRONE-001)',
          amount: 25000, # $250.00
          currency: 'usd',
          quantity: 1
        }]
      })
      [200, {'Content-Type' => 'application/json'}, [JSON.generate({
        invoice_id: invoice.id,
        amount: '$250.00',
        status: invoice.status
      })]]
    rescue Stripe::StripeError => e
      [400, {'Content-Type' => 'application/json'}, [JSON.generate({error: e.message})]]
    end
    
  else
    [404, {'Content-Type' => 'text/plain'}, ['Thomas IT Drone HQ']]
  end
end

run app
