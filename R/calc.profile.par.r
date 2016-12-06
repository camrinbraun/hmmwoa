#' Calculate WOA profile in parallel
#' 
#' Calculate Depth-temperature profile based likelihood
#' 
#' \code{calc.profile.par} calculates likelihood of animal position based on 
#' summarized depth-temperature profiles
#' 
#' Tag-based depth-temperature profile summaries are compared to climatological 
#' profiles from the World Ocean Atlas (WOA) "matched" to generate position likelihoods. This essentially
#' attempts to estimate animal position based on the water mass it is in,
#' particularly if extensive diving performs thorough sampling of the
#' environment. However, remember the in situ data is being compared to
#' climatological means or the results of an oceanographic model.
#' 
#' @param pdt is PDT data from WC psat tag summarizing depth/temperature data 
#'   over a programmed time interval
#' @param ptt is unique tag identifier
#' @param dat is monthly global 1/4deg climatology data from WOA13
#' @param lat is vector of latitudes from dat. 
#' @param lon is vector of longitudes from dat. 
#' @param dateVec is vector of dates from tag to pop-up in 1 day increments.
#' @export
#' @return raster brick of likelihood
#' @seealso \code{\link{calc.ohc}}
#' @examples 
#' \dontrun{
#' # depth-temp profile data
#' pdt <- read.wc(ptt, wd = myDir, type = 'pdt', tag=tag, pop=pop); 
#' pdt.udates <- pdt$udates; pdt <- pdt$data
#' 
#' # GENERATE DAILY PROFILE LIKELIHOODS
#' L.prof <- calc.profile(pdt, ptt, dateVec = dateVec, envType = 'hycom',
#'                        hycom.dir = hycom.dir)
#' # OR FOR WOA DATA:
#' L.prof.woa <- calc.profile(pdt, dat = woa, lat = lat, lon = lon,
#'                            dateVec = dateVec, envType = 'woa')
#' }
#'

calc.profile.par <- function(pdt, ptt, dat = NULL, lat = NULL, lon = NULL, dateVec, ncores = detectCores()){
  
  options(warn=-1)
  start.t <- Sys.time()
  
  if(is.null(dat) | is.null(lat) | is.null(lon)){
      stop('Error: dat, lat, lon must all be specified')
    }
  depth <- c(0, seq(2.5, 97.5, by=5), seq(112.5, 487.5, by=25), seq(525, 1475, by=50))

  
  # get unique time points
  dateVec = parse_date_time(dateVec, '%Y-%m-%d')
  
  udates <- unique(parse_date_time(pdt$Date, orders = '%Y-%m-%d %H%:%M:%S'))
  T <- length(udates)
  
  pdt$MidTemp <- (pdt$MaxTemp + pdt$MinTemp) / 2
  
  print(paste0('Generating WOA likelihood for ', udates[1], ' through ', udates[length(udates)]))
  print('processing in parallel... ')
  
  cl = makeCluster(ncores)
  registerDoParallel(cl, cores = ncores)
  
  L.prof <- array(0, dim = c(dim(dat)[1:2], length(dateVec)))
  
ans = foreach(i = 1:T) %dopar%{
    
    # define time based on tag data
    time <- as.Date(udates[i])
    pdt.i <- pdt[which(pdt$Date == time),]
    
    #extracts depth from tag data for day i
    y <- pdt.i$Depth[!is.na(pdt.i$Depth)] 
    y[y < 0] <- 0
    
    #extract temperature from tag data for day i
    x <- pdt.i$MidTemp[!is.na(pdt.i$Depth)]  
    
    # use the which.min
    depIdx = apply(as.data.frame(pdt.i$Depth), 1, FUN=function(x) which.min((x-depth)^2))
    
    # make predictions based on the regression model earlier for the temperature at standard WOA depth levels for low and high temperature at that depth
    fit.low <- locfit::locfit(pdt.i$MinTemp ~ pdt.i$Depth)
    fit.high <- locfit::locfit(pdt.i$MaxTemp ~ pdt.i$Depth)
    n = length(depth[depIdx])
    
    pred.low <- stats::predict(fit.low, newdata = depth[depIdx], se = T, get.data = T)
    pred.high <- stats::predict(fit.high, newdata = depth[depIdx], se = T, get.data = T)
    
    # data frame for next step
    df = data.frame(low = pred.low$fit - pred.low$se.fit * sqrt(n),
                    high = pred.high$fit + pred.high$se.fit * sqrt(n),
                    depth = depth[depIdx])
    

      
      if(i == 1){
        pdtMonth <- as.numeric(format(as.Date(pdt.i$Date), format = '%m'))[1]
      } 
      
      newMonth <- as.numeric(format(as.Date(pdt.i$Date), format = '%m'))[1]
      
      if(i == 1 | newMonth != pdtMonth) {
        # calculates sd but "if" statement ensures it is only calculated at
        # the beginning and when the date switches into a new month
        # because it's relatively computationally intensive
        
        pdtMonth <- as.numeric(format(as.Date(pdt.i$Date), format = '%m'))[1]
        dat.i = dat[,,,pdtMonth] #extract months climatology
        
        # calculate sd using Le Bris neighbor method and focal()
        sd.i = array(NA, dim = c(dim(dat.i)[1:2], length(depth)))
        
        for(ii in 1:length(depth)){
          r = raster::flip(raster::raster(t(dat.i[,,ii])), 2)
          f1 = raster::focal(r, w = matrix(1, nrow = 3, ncol = 3), fun = function(x) stats::sd(x, na.rm = T))
          f1 = t(raster::as.matrix(raster::flip(f1, 2)))
          sd.i[,,ii] = f1
        }
        
      }
    
    print(paste('Calculating likelihood for ', as.Date(time), '...', sep=''))

    # setup the likelihood array for each day. Will have length (dim[3]) = n depths
    lik.pdt = array(NA, dim = c(dim(dat.i)[1], dim(dat.i)[2], length(depIdx)))

    for (b in 1:length(depIdx)) {
        #calculate the likelihood for each depth level, b
        lik.pdt[,,b] = likint3(dat.i[,,depIdx[b]], sd.i[,,depIdx[b]], df[b,1], df[b,2])
      }
    # multiply likelihood across depth levels for each day
    lik.pdt <- apply(lik.pdt, 1:2, prod, na.rm = F)
  }
  
stopCluster(cl)

# make index of dates for filling in lik.prof

didx = match(udates, dateVec)

# 
# # identify date index and add completed likelihood to L.pdt array    
# idx <- which(dateVec == as.Date(time))
# L.prof[,,idx] = (lik.pdt / max(lik.pdt, na.rm=T)) - 0.2

# lapply 
lik.pdt = lapply(ans, function(x) x/max(x, na.rm = T)-0.2)

ii = 1
for(i in didx){
  L.prof[,,i] = lik.pdt[[ii]]
  ii = ii+1  
}


print(paste('Making final likelihood raster...'))
  
crs <- "+proj=longlat +datum=WGS84 +ellps=WGS84"
list.pdt <- list(x = lon, y = lat, z = L.prof)
ex <- raster::extent(list.pdt)
L.prof <- raster::brick(list.pdt$z, xmn = ex[1], xmx = ex[2], ymn = ex[3], ymx = ex[4], transpose = T, crs)
L.prof <- raster::flip(L.prof, direction = 'y')

options(warn = 2)
L.prof
  
}

