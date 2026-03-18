// Thomas IT Phase 7 - Realtime Analytics Dashboard
const charts = {};

function initCharts() {
  charts.swapVelocity = new Chart(
    document.getElementById('swapVelocityChart'),
    {
      type: 'line',
      data: { 
        labels: [], 
        datasets: [{ 
          label: 'Swaps/Hour', 
          data: [], 
          borderColor: '#3B82F6', 
          backgroundColor: 'rgba(59, 130, 246, 0.1)',
          fill: true,
          tension: 0.4
        }] 
      },
      options: { 
        responsive: true, 
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true } },
        plugins: { legend: { display: true } }
      }
    }
  );

  charts.droneSuccess = new Chart(
    document.getElementById('droneSuccessChart'),
    {
      type: 'doughnut',
      data: { 
        labels: ['✅ Success', '❌ Failed'], 
        datasets: [{ 
          data: [87, 13], 
          backgroundColor: ['#10B981', '#EF4444'],
          borderWidth: 0
        }] 
      },
      options: { 
        responsive: true,
        maintainAspectRatio: false,
        plugins: { 
          legend: { position: 'bottom' },
          tooltip: { 
            callbacks: {
              label: function(context) {
                return `${context.label}: ${context.parsed.toFixed(1)}%`;
              }
            }
          }
        }
      }
    }
  );

  charts.techLeaderboard = new Chart(
    document.getElementById('techLeaderboardChart'),
    {
      type: 'bar',
      data: { 
        labels: [], 
        datasets: [{ 
          label: 'Swaps (7d)', 
          data: [], 
          backgroundColor: '#8B5CF6',
          borderRadius: 8,
          borderSkipped: false
        }] 
      },
      options: { 
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true } },
        plugins: { legend: { display: false } }
      }
    }
  );
}

async function fetchDashboardData() {
  try {
    const res = await fetch('/api/analytics/dashboard');
    const data = await res.json();
    updateCharts(data);
  } catch (e) { 
    console.error('Dashboard fetch failed:', e); 
  }
}

function updateCharts(data) {
  // Swap Velocity
  charts.swapVelocity.data.labels = Object.keys(data.swap_velocity || {});
  charts.swapVelocity.data.datasets[0].data = Object.values(data.swap_velocity || {});
  charts.swapVelocity.update('none');

  // Drone Success  
  const droneData = data.drone_success || { rate: 0, total: 0 };
  charts.droneSuccess.data.datasets[0].data = [droneData.rate, 100 - droneData.rate];
  charts.droneSuccess.update('none');

  // Tech Leaderboard
  const leaderboard = data.tech_leaderboard || [];
  charts.techLeaderboard.data.labels = leaderboard.map(t => t[0]);
  charts.techLeaderboard.data.datasets[0].data = leaderboard.map(t => t[1]);
  charts.techLeaderboard.update('none');
}

// Auto-refresh every 30s + ActionCable
setInterval(fetchDashboardData, 30000);
document.addEventListener('DOMContentLoaded', () => {
  initCharts();
  fetchDashboardData();
  
  // ActionCable realtime updates
  if (typeof ActionCable !== 'undefined') {
    ActionCable.createConsumer()
      .subscriptions.create("SwapUpdatesChannel", {
        received() { fetchDashboardData(); }
      });
  }
});
