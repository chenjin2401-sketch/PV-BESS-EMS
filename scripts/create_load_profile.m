clear; clc; close all;

% Simulation time settings
dt = 900;                     % 15 minutes = 900 seconds
T_end = 24 * 3600;            % 24 hours in seconds
t = (0:dt:T_end)';            % Simulation time vector
hour = t / 3600;              % Convert seconds to hours

% Hourly commercial-load reference points (kW)
% Values correspond to 00:00, 01:00, ..., 24:00
load_hourly = [ ...
    40 38 36 35 35 36 42 60 80 95 105 110 108 ...
    100 95 92 98 115 135 140 128 105 78 58 45]';

hour_nodes = (0:24)';

% Generate a smooth 15-minute load profile
P_Load = interp1(hour_nodes, load_hourly, hour, 'pchip');

% Engineering safety check: load must not be negative
P_Load(P_Load < 0) = 0;

% Package the profile for later use in Simulink
load_profile = timeseries(P_Load, t);

% Calculate daily electricity consumption
E_Load_kWh = trapz(t, P_Load) / 3600;

% Plot the load curve
figure('Color', 'w');
plot(hour, P_Load, 'b-', 'LineWidth', 2);
grid on;
xlim([0 24]);
ylim([0 160]);
xlabel('Time of day (h)');
ylabel('Load power (kW)');
title('Typical Commercial Load Profile');

% Save variables to the project data folder
scriptFolder = fileparts(mfilename('fullpath'));
projectFolder = fileparts(scriptFolder);
dataFolder = fullfile(projectFolder, 'data');

save(fullfile(dataFolder, 'load_profile.mat'), ...
    'load_profile', 't', 'hour', 'P_Load', 'dt', 'E_Load_kWh');

fprintf('Daily load energy = %.1f kWh\n', E_Load_kWh);
fprintf('Peak load = %.1f kW\n', max(P_Load));