#################################################################################################################################################
############################################ FFM Days above 40C 2026 vs Rest of Dates ###########################################################

library(tidyverse)
library(magrittr)
library(httr)
library(lubridate)
library(glue)
library(janitor)


##### 1. SETTINGS ####

# Station Name and ID
station_id = "01420"
station_name = "Frankfurt/Main"

# Endpoint as of 12. Aug 26
end_date = as.Date("2026-08-12")

# Extreme-temperature definition
extreme_threshold = 40

# Climatological reference period
climatology_start = 1991
climatology_end = 2020


#### 2. DWD DATA LOCATIONS ####

dwd_base =
  paste0(
    "https://opendata.dwd.de/",
    "climate_environment/CDC/",
    "observations_germany/climate/daily/kl/"
  )

historical_url = paste0(
  dwd_base,
  "historical/"
)

recent_url = paste0(
  dwd_base,
  "recent/"
)


#### 3. FUNCTION TO FIND DWD ZIP FILES FOR THE STATION ####

find_dwd_files = function(
  directory_url,
  station_id) {

  response = GET(
    directory_url
  )

  stop_for_status(
    response
  )

  html = content(
    response,
    as = "text",
    encoding = "UTF-8"
  )

  pattern = paste0(
    'href="([^"]*tageswerte_KL_',          # here simple quotations important, do not use ""
    station_id,
    '[^"]*\\.zip)"'
  )

  matches = str_match_all(
    html,
    regex(
      pattern,
      ignore_case = TRUE
    )
  )[[1]]

  if (nrow(matches) == 0) {

    stop(
      paste0(
        "No DWD files found for station ",
        station_id,
        " in ",
        directory_url
      )
    )
  }

  filenames = unique(
    matches[, 2]
  )

  paste0(
    directory_url,
    filenames
  )
}


#### 4. FINDING HISTORICAL AND RECENT FILES ####

historical_files = find_dwd_files(
  historical_url,
  station_id
)

recent_files = find_dwd_files(
  recent_url,
  station_id
)

cat(
  "\nHistorical files:\n"
)

print(
  historical_files
)

cat(
  "\nRecent files:\n"
)

print(
  recent_files
)


#### 5. FUNCTION TO DOWNLOAD AND READ ONE DWD ZIP FILE ####

read_dwd_zip = function(
  url,
  source_name) {

  zip_file = tempfile(
    fileext = ".zip"
  )

  extract_dir = tempfile()

  dir.create(
    extract_dir
  )

  message(
    "Downloading: ",
    url
  )

  response = GET(
    url,
    write_disk(
      zip_file,
      overwrite = TRUE
    )
  )

  stop_for_status(
    response
  )

  unzip(
    zip_file,
    exdir = extract_dir
  )

  txt_files = list.files(
    extract_dir,
    pattern = "produkt_klima_tag.*\\.txt$",
    full.names = TRUE,
    ignore.case = TRUE
  )

  if (length(txt_files) == 0) {

    stop(
      paste0(
        "No daily climate file found inside:\n",
        url
      )
    )
  }

  result = map_dfr(
    txt_files,
    function(x) {

      message(
        "Reading: ",
        x
      )

      read_delim(
        x,
        delim = ";",
        trim_ws = TRUE,
        na = c(
          "-999",
          "-999.0",
          "-999.00"
        ),
        show_col_types = FALSE
      ) %>%
        clean_names()
    }
  )

  result %>%
    mutate(
      source = source_name
    )
}


#### 6. DOWNLOADING HISTORICAL DATA ####

historical_data = map_dfr(
  historical_files,
  function(x) {

    read_dwd_zip(
      x,
      "historical"
    )
  }
)


#### 7. DOWNLOADING RECENT DATA ####

recent_data = map_dfr(
  recent_files,
  function(x) {

    read_dwd_zip(
      x,
      "recent"
    )
  }
)


#### 8. COMBINING HISTORICAL + RECENT DATA ####

frankfurt_raw = bind_rows(
  historical_data,
  recent_data
)


#### 9. CHECKING VARIABLES ####

print(
  names(
    frankfurt_raw
  )
)

# DWD variables important here:
#
# stations_id = station ID
# mess_datum  = date YYYYMMDD
# txk         = daily maximum air temperature
#
# TXK corresponds to the daily maximum temperature.


#### 10. PREPARING THE FRANKFURT DATA ####

frankfurt = frankfurt_raw %>%
  mutate(

    stations_id = str_pad(
      as.character(
        stations_id
      ),
      width = 5,
      side = "left",
      pad = "0"
    ),

    mess_datum = as.character(
      mess_datum
    ),

    date = ymd(
      mess_datum
    ),

    tx = as.numeric(
      txk
    ),

    year = year(
      date
    ),

    source_priority = if_else(
      source == "recent",
      1,
      0
    )
  ) %>%

  filter(
    stations_id == station_id,
    !is.na(date),
    !is.na(tx)
  ) %>%

  # Prefer recent data if historical/recent overlap
  arrange(
    date,
    desc(source_priority)
  ) %>%

  distinct(
    date,
    .keep_all = TRUE
  ) %>%

  arrange(
    date
  )


#### 11. CHECKS FOR AVAILABLE PERIOD ####

cat(
  "\nFirst available observation:\n"
)

print(
  min(
    frankfurt$date
  )
)

cat(
  "\nLatest available observation:\n"
)

print(
  max(
    frankfurt$date
  )
)


#### 12. ENDPOINT 11 AUG 2026 ####

frankfurt %<>%
  filter(
    date <= end_date
  )

# Actual endpoint used
latest_date = max(
  frankfurt$date,
  na.rm = TRUE
)

# First year of available data
first_year = min(
  frankfurt$year,
  na.rm = TRUE
)

cat(
  "\nPeriod used in figure:\n",
  min(frankfurt$date),
  "to",
  latest_date,
  "\n"
)


#### 13. PUTTING ALL YEARS ON SAME JAN-DEC X-AXIS ####
# 2024 is used as dummy year because it is a leap year

frankfurt %<>%
  mutate(

    month_day = format(
      date,
      "%m-%d"
    ),

    plot_date = as.Date(
      paste0(
        "2024-",
        month_day
      )
    )
  )


#### 14. CLIMATOLOGICAL MEAN 1991-2020 ####

climatology = frankfurt %>%
  filter(
    year >= climatology_start,
    year <= climatology_end
  ) %>%

  group_by(
    plot_date
  ) %>%

  summarise(

    average = mean(
      tx,
      na.rm = TRUE
    ),

    .groups = "drop"
  )


#### 15. EXTREME DAYS BEFORE 2026 ####

extreme_old = frankfurt %>%
  filter(
    year <= 2025,
    tx >= extreme_threshold
  )


#### 16. EXTREME DAYS DURING 2026 ####

extreme_2026 = frankfurt %>%
  filter(
    year == 2026,
    tx >= extreme_threshold # temperature tx
  )


#### 17. CHECKING EXTREME VALUES ####

cat(
  "\n",
  first_year,
  "-2025 >= ",
  extreme_threshold,
  " °C:\n",
  sep = ""
)

print(
  extreme_old |>
    select(
      date,
      tx
    ) |>
    arrange(
      date
    )
)

cat(
  "\n2026 >= ",
  extreme_threshold,
  " °C:\n",
  sep = ""
)

print(
  extreme_2026 |>
    select(
      date,
      tx
    ) |>
    arrange(
      date
    )
)


#### 18. NUMBER OF EXTREME DAYS ####

n_old = nrow(
  extreme_old
)

n_2026 = nrow(
  extreme_2026
)

cat(
  "\nHistorical extreme days: ",
  n_old,
  "\n",
  sep = ""
)

cat(
  "2026 extreme days: ",
  n_2026,
  "\n",
  sep = ""
)


#### 19. FUNCTION FOR EXTREME-TEMPERATURE TEXT ####

create_extreme_text = function(data) {

  if (nrow(data) == 0) {

    return(
      paste0(
        "No days \u2265 ",
        extreme_threshold,
        "\u00b0C"
      )
    )
  }

  data %>%
    arrange(
      desc(date)
    ) %>%

    mutate(

      label = paste0(

        format(
          date,
          "%d/%m/%Y"
        ),

        " : ",

        sprintf(
          "%.1f",
          tx
        ),

        "\u00b0C"
      )
    ) %>%

    pull(
      label
    ) %>%

    paste(
      collapse = "\n"
    )
}


#### 20. CREATING A TEXT FOR HISTORICAL EXTREMES ####

old_text = create_extreme_text(
  extreme_old
)


#### 21. CREATING A TEXT FOR 2026 EXTREMES ####

new_text = create_extreme_text(
  extreme_2026
)


#### 22. LABELS USED IN FIGURE ####

historical_label = paste0(
  first_year,
  " - 2025"
)

latest_date_text = format(
  latest_date,
  "%d/%m/%Y"
)


#### 23. PLOTTING ####

p = ggplot() +

  # All daily max temps
  geom_point(
    data = frankfurt %>%
      filter(
        tx < extreme_threshold),
    aes(
      x = plot_date,
      y = tx,
      colour = "< 40°C"),
    alpha = 0.10,
    size = 0.65
  ) +

  # Historical >= 40C
  geom_point(
    data = extreme_old,
    aes(
      x = plot_date,
      y = tx,
      colour = historical_label),
    size = 2.2
  ) +

  # 2026 >= 40C
  geom_point(
    data = extreme_2026,
    aes(
      x = plot_date,
      y = tx,
      colour = "2026"),
    size = 3.6
  ) +

  # climatological average
  geom_line(
    data = climatology,
    aes(
      x = plot_date,
      y = average,
      colour = "Average"),
    linewidth = 1.25
  ) +

  # 40C threshold line
  geom_hline(
    yintercept = extreme_threshold,
    linetype = "dotdash",
    linewidth = 0.5,
    colour = "grey25"
  ) +

  # Historical extreme table inside plot area
  annotate(
    "text",
    x = as.Date(
      "2024-05-20"),
    y = -5,
    label = paste0(
      historical_label,
      "\n",
      old_text),
    hjust = 0,
    vjust = 1,
    size = 3.4,
    fontface = "bold.italic"
  ) +

  # 2026 extreme table
  annotate(
    "text",
    x = as.Date(
      "2024-08-05"),
    y = -5,
    label = paste0(
      "2026\n",
      new_text),
    hjust = 0,
    vjust = 1,
    size = 3.4,
    fontface = "bold.italic",
    colour = "red"
  ) +

  # Upper-right annotation
  annotate(
    "text",
    x = as.Date(
      "2024-12-25"),
    y = 46,
    label = paste0(
      "Climatology Reference: ",
      climatology_start,
      "-",
      climatology_end,
      "\n",
      "Extremes: ",
      first_year,
      "-2026"),
    hjust = 1,
    vjust = 0,
    size = 4,
    fontface = "bold"
  ) +

  annotate(
    "text",
    x = as.Date(
      "2024-12-25"),
    y = 41.5,
    label = paste0(
      "Latest data: ",
      latest_date_text),
    hjust = 1,
    vjust = 1,
    size = 3,
    fontface = "italic"
  ) +

  # X AXIS
  scale_x_date(
    date_breaks = "1 month",
    date_labels = "%b",
    limits = as.Date(
      c(
        "2024-01-01",
        "2024-12-31")),
    expand = expansion(
      mult = c(0, 0))
  ) +
  
  # Y AXIS
  scale_y_continuous(
    breaks = seq(
      -20,
      40,
      10),
    limits = c(
      -20,
      48),
    expand = expansion(
      mult = c(0, 0))
  ) +

  coord_cartesian(
    ylim = c(-16, 45),
    clip = "off"
  ) +

  # COLOUR SCALE / LEGEND
  scale_colour_manual(
    name = NULL,
    values = setNames(
      c(
        "grey35",
        "black",
        "red",
        "grey30"),
      c(
        "< 40°C",
        historical_label,
        "2026",
        "Average")),
    labels = setNames(
      c(
        "Daily highs < 40°C",
        paste0(
          historical_label,
          " ≥ ",
          extreme_threshold,
          "°C: ",
          n_old,
          " days"),
        paste0(
          "2026 ≥ ",
          extreme_threshold,
          "°C: ",
          n_2026,
          " days"),
        paste0(
          "Average ",
          climatology_start,
          "-",
          climatology_end)),
      c(
        "< 40°C",
        historical_label,
        "2026",
        "Average"))
  ) +

  guides(
    colour = guide_legend(
      override.aes = list(
        alpha = 1))
  ) +

  # LABELS
  labs(
    title =
      "Daily High Temperature",
    subtitle =
      "Frankfurt/Main, Hessen, Germany",
    x = NULL,
    y = "Temperature (\u00b0C)",
    caption = paste0(
      "Source: Deutscher Wetterdienst (DWD), ",
      "Climate Data Center (CDC), ",
      "Station 01420 Frankfurt/Main",
      "\nElaboration: David Bustamante (https://github.com/DavidBustamanteL)")
  ) +

  # THEME
  theme_minimal(
    base_size = 15) +
  theme(
    plot.title = element_text(
      size = 25,
      face = "bold",
      hjust = 0),
    plot.subtitle = element_text(
      size = 20,
      hjust = 0),
    axis.title.y = element_text(
      size = 16),
    axis.text = element_text(
      size = 14,
      colour = "grey20"),
    panel.grid.minor =
      element_blank(),
    panel.grid.major =
      element_line(
        linewidth = 0.35,
        colour = "grey85"),
    panel.border =
      element_rect(
        colour = "grey20",
        fill = NA,
        linewidth = 0.8),
    legend.position =
      c(0.10, 0.91),
    legend.background =
      element_rect(
        fill = "white",
        colour = "grey75"),
    legend.key =
      element_blank(),
    legend.text =
      element_text(
        size = 11),
    plot.caption =
      element_text(
        hjust = 0,
        face = "bold",
        size = 9),
    plot.margin =
      margin(
        15,
        15,
        10,
        15))

p


#### 24. OPTIONAL SAVE ####

ggsave(
  filename = 
    "frankfurt_daily_high_temperature.png",
  plot = p,
  width = 14,
  height = 9,
  dpi = 300
)